#!/usr/bin/env perl
# ABOUTME: A session cart is one charge: every child's first share summed, no offer version on the row, each line in its metadata.
# ABOUTME: A cart with an instalment child saves the card and its customer for the later instalments; a one-time cart does neither.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::Offers qw( instalment_plan );
use Test::Registry::Async qw( settle );
use Mojo::Promise;
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::Service::Stripe;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# registry sells its own sessions here, on a ready account under Solo's 2.5%.
my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => '0.025' } );

# A placeholder: every Stripe call below is swapped for one that records it.
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'cart_pay_parent', name => 'Cart Payer', email => 'cart_pay@test.example' } );
sub child ($name) {
    Registry::DAO::FamilyMember->create( $db, { family_id => $parent->id, child_name => $name, birth_date => '2016-01-01' } );
}
my ( $kid, $sib ) = ( child('Kid'), child('Sib') );

sub session () { scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] ) }
sub full_price ($s) { session_offer( $db, $s, price_cents => 30000 ) }
sub in_parts ($s) {
    session_offer( $db, $s, price_cents => 27000,
        policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'end' } },
        payment_plans => [ { id => 'pay', kind => 'one_time' }, instalment_plan( id => 'parts', count => 3, cadence => 'weekly' ) ] );
}

# A cart held and owing, each line [ child, session, version, plan ].
sub cart (@lines) {
    held_cart( $dao, $parent->id, map { [ $_->[0]->id, $_->[1]->id, $_->[2]->id, $_->[3] ] } @lines );
}
# Kid at $300 once, Sib at $270 in three weekly parts of $90.
sub mixed_cart () {
    my $s = session();
    return cart( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, in_parts($s), 'parts' ] );
}

sub data_of ($run) { Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data }
sub payments_of ($run) {
    $db->query( q{SELECT * FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )->expand->hashes->to_array;
}

# Drives the payment step as a POST does, recording what reaches Stripe.
sub charge ( $run, $pay ) {
    my ( @customers, @intents );
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_customer_async = sub ( $s, $p ) {
        push @customers, $p;
        Mojo::Promise->resolve( { id => 'cus_cart_' . @customers } );
    };
    local *Registry::Service::Stripe::create_payment_intent_async = sub ( $s, $p ) {
        push @intents, {%$p};
        Mojo::Promise->resolve( { id => 'pi_cart_' . @intents, client_secret => 'pi_cart_secret' } );
    };
    my $out = settle( $run->process( $db, $pay, {} ) );
    return ( $out, \@customers, \@intents );
}

subtest 'the cart is one payment of 39000 with two lines and no offer version' => sub {
    my ( $run, $pay ) = mixed_cart();
    my $owed = $pay->owed_payment( $db, $run );
    my $payment = $owed->{payment} or return fail 'no payment: ' . explain $owed;

    my $rows = payments_of($run);
    is scalar @$rows, 1, 'one payment row';
    is $rows->[0]{amount_cents}, 39000, 'for both first shares, $300 and $90';
    is $rows->[0]{offer_version_id}, undef, 'with no offer version: each line names its own';
    my $lines = $rows->[0]{metadata}{lines};
    is scalar @$lines, 2, 'and two lines';
    is_deeply $lines, data_of($run)->{owed_payment}{lines}, 'the lines the hold wrote';
    is_deeply [ map { $_->{share_cents} } @$lines ], [ 30000, 9000 ], 'each with its share';
    is_deeply [ map { [ $_->{amount_cents}, $_->{due_date} =~ /\A\d{4}-\d\d-\d\d\z/ ? 'dated' : 'undated' ] }
            $lines->[1]{parts}->@* ], [ ( [ 9000, 'dated' ] ) x 3 ],
        "the instalment line's parts and due dates, for its schedule";
    is data_of($run)->{owed_payment_id}, $payment->id, 'the run names its payment';

    $pay->owed_payment( $db, $run );
    is scalar @{ payments_of($run) }, 1, 'asked again, the same row';
};

subtest 'an instalment line saves the card' => sub {
    my ( $run, $pay ) = mixed_cart();
    my ( $out, $customers, $intents ) = charge( $run, $pay );
    ok !$out->{errors}, 'the card form is offered' or diag explain $out;
    my $payment = Registry::DAO::Payment->find( $db, { id => data_of($run)->{owed_payment_id} } );
    ok $payment->saves_card, 'the payment saves the card';
    is scalar @$customers, 1, 'a Stripe customer is made for the payer';
    is scalar @$intents, 1, 'one intent';
    is $intents->[0]{setup_future_usage}, 'off_session', 'which keeps the card for the instalments to come';
    is $intents->[0]{customer}, 'cus_cart_1', "on the payer's customer";
    is $intents->[0]{amount}, 39000, 'for the whole first charge';
    is $intents->[0]{application_fee_amount}, 975, "with Solo's 2.5%";
};

subtest 'a one-time cart does not save the card' => sub {
    my $s = session();
    my ( $run, $pay ) = cart( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, full_price($s), 'pay' ] );
    my ( $out, $customers, $intents ) = charge( $run, $pay );
    ok !$out->{errors}, 'the card form is offered' or diag explain $out;
    my $payment = Registry::DAO::Payment->find( $db, { id => data_of($run)->{owed_payment_id} } );
    ok !$payment->saves_card, 'the payment keeps no card';
    is scalar @$customers, 0, 'no Stripe customer is made';
    is $intents->[0]{amount}, 60000, 'one intent for both children';
    ok !exists $intents->[0]{setup_future_usage}, 'that does not keep the card';
    ok !exists $intents->[0]{customer}, 'nor name a customer';
};

subtest 'a tampered share is refused with no row written' => sub {
    my ( $run, $pay ) = mixed_cart();
    my $owed = data_of($run)->{owed_payment};
    $owed->{lines}[0]{share_cents} = 100;
    $run->update_data( $db, { owed_payment => $owed } );

    my ( $out, $customers, $intents ) = charge( $run, $pay );
    is_deeply $out->{errors}, ['The shares in this cart do not add up to what is owed.'], 'refused';
    is scalar @{ payments_of($run) }, 0, 'no payment row';
    is scalar(@$customers) + scalar(@$intents), 0, 'and nothing sent to Stripe';
    ok !data_of($run)->{owed_payment_id}, 'the run names no payment';
};

subtest 'without a stripe key the charge is refused' => sub {
    my ( $run, $pay ) = mixed_cart();
    delete local $ENV{STRIPE_SECRET_KEY};

    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    my ( $out, $customers, $intents ) = charge( $run, $pay );
    is_deeply $out->{errors}, ['This payment cannot be taken right now. Nothing has been charged.'], 'refused';
    like "@warned", qr/STRIPE_SECRET_KEY is not set/, 'the refusal is logged';
    is scalar @{ payments_of($run) }, 0, 'no payment row';
    is scalar(@$customers) + scalar(@$intents), 0, 'and nothing sent to Stripe';
    is $db->query( q{SELECT count(*) FROM holds WHERE workflow_run_id = ? AND state = 'held'}, $run->id )->array->[0], 2,
        "each child's seat stays held";
};

subtest 'one lapsed hold refuses the whole charge' => sub {
    my ( $run, $pay ) = mixed_cart();
    my ( $a, $b ) = map { $_->{hold_id} } data_of($run)->{owed_payment}{lines}->@*;
    # B's seat lapsed while the parent was away; A's is still held.
    $db->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 minute' WHERE id = ?}, $b );
    my $a_expires = $db->query( 'SELECT expires_at FROM holds WHERE id = ?', $a )->array->[0];

    my ( $out, $customers, $intents ) = charge( $run, $pay );
    is_deeply $out->{errors}, ['The seats held for this payment lapsed. Nothing has been charged.'], 'refused';
    is $db->query( 'SELECT state FROM holds WHERE id = ?', $b )->array->[0], 'released', "B's lapsed hold is released";
    is $db->query( 'SELECT state FROM holds WHERE id = ?', $a )->array->[0], 'held', "A's stays held";
    is $db->query( 'SELECT expires_at FROM holds WHERE id = ?', $a )->array->[0], $a_expires, 'and is not extended';
    is scalar(@$customers) + scalar(@$intents), 0, 'nothing is sent to Stripe';
    is scalar @{ payments_of($run) }, 0, 'and no payment row is written';
};

# What a faulty hold step could write: shares that still sum to the amount.
subtest 'a share that disagrees with its price is refused with no row written' => sub {
    my @cases = (
        [ 'a one-time share off its price', sub ($l) { $l->[0]{share_cents} -= 100; $l->[1]{share_cents} += 100;
                                                       $l->[1]{parts}[0]{amount_cents} += 100 } ],
        [ 'instalment parts re-split', sub ($l) { $l->[1]{parts}[1]{amount_cents} += 100;
                                                  $l->[1]{parts}[2]{amount_cents} -= 100 } ],
        [ 'an instalment share off its first part', sub ($l) { $l->[0]{share_cents} += 100; $l->[1]{share_cents} -= 100 } ],
        [ 'a due date moved', sub ($l) { $l->[1]{parts}[2]{due_date} = '2099-01-01' } ],
        [ 'a part dropped', sub ($l) { pop $l->[1]{parts}->@* } ],
    );
    for my $case (@cases) {
        my ( $name, $tamper ) = @$case;
        my ( $run, $pay ) = mixed_cart();
        my $owed = data_of($run)->{owed_payment};
        $tamper->( $owed->{lines} );
        my $sum = 0;
        $sum += $_->{share_cents} for $owed->{lines}->@*;
        is $sum, $owed->{amount_cents}, "$name: the shares still sum";
        $run->update_data( $db, { owed_payment => $owed } );

        my ( $out, $customers, $intents ) = charge( $run, $pay );
        is_deeply $out->{errors}, ['A price in this cart cannot be sold.'], "$name: refused";
        is scalar @{ payments_of($run) }, 0, "$name: no payment row";
        is scalar(@$customers) + scalar(@$intents), 0, "$name: nothing sent to Stripe";
    }
};

# A cart whose first card was declined: the run, its payment step, and the
# declined payment whose intent is pi_cart_1. %stripe swaps further service
# methods for the retry.
sub declined_cart () {
    my ( $run, $pay ) = mixed_cart();
    charge( $run, $pay );
    my $declined = Registry::DAO::Payment->find( $db, { id => data_of($run)->{owed_payment_id} } );
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $s, $id ) {
        Mojo::Promise->resolve( { id => $id, status => 'requires_payment_method',
            last_payment_error => { message => 'Your card was declined.' } } );
    };
    settle( $run->process( $db, $pay, { payment_intent_id => 'pi_cart_1' } ) );
    is $declined->stripe_payment_intent_id, 'pi_cart_1', 'the first intent was pi_cart_1';
    return ( $run, $pay, Registry::DAO::Payment->find( $db, { id => $declined->id } ) );
}

subtest 'a retry after a decline cancels the declined intent first' => sub {
    my ( $run, $pay, $declined ) = declined_cart();
    is $declined->status, 'failed', 'declined';
    my @cancelled;
    no warnings 'redefine';
    local *Registry::Service::Stripe::cancel_payment_intent_async = sub ( $s, $id, $p = {} ) {
        push @cancelled, [ $id, $p->{_idempotency_key}, $s->stripe_account ];
        Mojo::Promise->resolve( { id => $id, status => 'canceled' } );
    };
    my ( $out, $customers, $intents ) = charge( $run, $pay );
    ok !$out->{errors}, 'a new card form is offered' or diag explain $out;
    is_deeply \@cancelled, [ [ 'pi_cart_1', 'pi-cancel:pi_cart_1', $declined->metadata->{stripe_account_id} ] ],
        "the declined intent is cancelled once, under its own key, on the seller's account";
    is scalar @$intents, 1, 'then one new intent';
    isnt data_of($run)->{owed_payment_id}, $declined->id, 'for a new payment row';
};

subtest 'a declined intent that succeeded meanwhile is taken as paid' => sub {
    my ( $run, $pay, $declined ) = declined_cart();
    no warnings 'redefine';
    # Another tab confirmed the first intent after all: Stripe will not cancel it.
    local *Registry::Service::Stripe::cancel_payment_intent_async = sub ( $s, $id, $p = {} ) {
        Mojo::Promise->reject("Stripe invalid_request_error: You cannot cancel this PaymentIntent because it has a status of succeeded.");
    };
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $s, $id ) {
        Mojo::Promise->resolve( { id => $id, status => 'succeeded', amount => 39000,
            payment_method => 'pm_card', metadata => { payment_id => $declined->id } } );
    };
    my ( $out, $customers, $intents ) = charge( $run, $pay );
    ok !$out->{errors} && !$out->{stay}, 'the run is handed on' or diag explain $out;
    is scalar @$intents, 0, 'no new intent is made';
    is Registry::DAO::Payment->find( $db, { id => $declined->id } )->status, 'completed', 'the first payment is completed';
    is scalar @{ payments_of($run) }, 1, 'and no second row is written';
};

subtest 'a declined intent still processing is waited on' => sub {
    my ( $run, $pay, $declined ) = declined_cart();
    no warnings 'redefine';
    local *Registry::Service::Stripe::cancel_payment_intent_async = sub ( $s, $id, $p = {} ) {
        Mojo::Promise->reject("Stripe invalid_request_error: You cannot cancel this PaymentIntent because it has a status of processing.");
    };
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $s, $id ) {
        Mojo::Promise->resolve( { id => $id, status => 'processing', metadata => { payment_id => $declined->id } } );
    };
    my ( $out, $customers, $intents ) = charge( $run, $pay );
    is_deeply $out->{errors}, ['Your earlier payment is still being processed. Nothing more has been charged.'], 'refused';
    is scalar @$intents, 0, 'no new intent is made';
    is scalar @{ payments_of($run) }, 1, 'and no second row';
};

done_testing;
