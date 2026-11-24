#!/usr/bin/env perl
# ABOUTME: Returning the platform's fee on a payment, the exception to keeping it on a refund.
# ABOUTME: The fee is found on the seller's charge and refunded on the platform's own account.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Test::Registry::PricingProbe qw(solo_linked_tenant);
use Registry::DAO::Payment;
use Registry::Service::Stripe;  # load package before glob replacement
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;     # Mojo::Pg::Database

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_fee_refund_tests';

my $tenant_slug = solo_linked_tenant($db);
$db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
    'acct_fee_tenant', $tenant_slug );

my $user_id = $db->query(q{
    INSERT INTO registry.users (username, passhash)
    VALUES ('fee_refund_test', 'nohash')
    RETURNING id
})->hash->{id};

my $n = 0;
sub a_payment (%over) {
    $n++;
    return Registry::DAO::Payment->create( $db, {
        user_id                  => $user_id,
        amount_cents             => 10000,
        status                   => 'completed',
        stripe_payment_intent_id => "pi_fee_refund_$n",
        metadata                 => { tenant_slug => $tenant_slug },
        %over,
    } );
}

# Stubs only the HTTP-facing calls, recording each with the account of the
# client that made it. The Payment method's own logic runs for real.
# %reply overrides the charge (latest_charge), the fee, or makes a call reject.
sub with_stripe ( $calls, $code, %reply ) {
    my $record = sub ( $what, $client, @args ) {
        push @$calls, { call => $what, account => $client->stripe_account, args => \@args };
    };
    my $answer = sub ($value) {
        ref $value eq 'HASH' ? Mojo::Promise->resolve($value) : Mojo::Promise->reject($value);
    };
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $client, @args ) {
        $record->( 'intent', $client, @args );
        return $answer->( exists $reply{intent} ? $reply{intent} : {
            id            => $args[0],
            latest_charge => $reply{charge} // {
                id => 'ch_fee', application_fee => 'fee_abc123', application_fee_amount => 250,
            },
        } );
    };
    local *Registry::Service::Stripe::retrieve_application_fee_async = sub ( $client, @args ) {
        $record->( 'fee', $client, @args );
        return $answer->( { id => $args[0], charge => 'ch_fee', account => 'acct_fee_tenant',
            amount => 250, amount_refunded => 0, %{ $reply{fee} // {} } } );
    };
    local *Registry::Service::Stripe::create_application_fee_refund_async = sub ( $client, @args ) {
        $record->( 'refund', $client, @args );
        return $answer->( { id => 'fr_' . scalar(@$calls), amount => $args[1]{amount} } );
    };
    $code->();
}

sub calls_of ( $calls, $what ) { [ grep { $_->{call} eq $what } @$calls ] }

subtest 'fee is found on the seller charge and refunded on the platform' => sub {
    my $payment = a_payment();
    my @calls;
    with_stripe( \@calls, sub {
        settle( $payment->refund_platform_fee_async( $db,
            { amount_cents => 100, idempotency_key => 'fee-refund:1' } ) );
    } );

    my ($intent) = @{ calls_of( \@calls, 'intent' ) };
    is $intent->{account}, 'acct_fee_tenant', 'the charge is read on the seller account';
    is $intent->{args}[0], $payment->stripe_payment_intent_id, 'through the payment intent';
    is_deeply $intent->{args}[1], { 'expand[]' => 'latest_charge' }, 'with its charge expanded';

    my $refunds = calls_of( \@calls, 'refund' );
    is scalar @$refunds, 1, 'one fee refund request';
    is $refunds->[0]{account}, undef, 'made by the platform, on no connected account';
    is $refunds->[0]{args}[0], 'fee_abc123', 'for the charge application fee';
    is $refunds->[0]{args}[1]{amount}, 100, 'for the given amount';
    is $refunds->[0]{args}[1]{_idempotency_key}, 'fee-refund:1', 'with the given idempotency key';
};

subtest 'without an amount the whole remaining fee is refunded' => sub {
    my $payment = a_payment();
    my @calls;
    with_stripe( \@calls, sub { settle( $payment->refund_platform_fee_async($db) ) },
        fee => { id => 'fee_abc123', amount => 250, amount_refunded => 50 } );

    my $refunds = calls_of( \@calls, 'refund' );
    is scalar @$refunds, 1, 'one fee refund request';
    is $refunds->[0]{args}[1]{amount}, 200, 'for what is left of the fee';
};

# Runs the fee refund and returns its error, or undef.
sub fee_refund_error ( $payment, $calls, $args = {}, %reply ) {
    my $err;
    with_stripe( $calls, sub {
        $err = $@ unless eval { settle( $payment->refund_platform_fee_async( $db, $args ) ); 1 };
    }, %reply );
    return $err;
}

subtest 'payment without intent is not sent' => sub {
    my $payment = a_payment( stripe_payment_intent_id => undef );
    my @calls;
    my $err = fee_refund_error( $payment, \@calls );

    like $err, qr/REFUND_NOT_SENT/, 'refused as not sent';
    is( Registry::DAO::Payment->classify_refund_failure($err), 'not_sent',
        'classified as certainly not sent' );
    is scalar @calls, 0, 'no request of any kind';
};

subtest 'charge without application fee is not sent' => sub {
    my $payment = a_payment();
    my @calls;
    my $err = fee_refund_error( $payment, \@calls, {},
        charge => { id => 'ch_zero', application_fee => undef, application_fee_amount => undef } );

    like $err, qr/REFUND_NOT_SENT/, 'refused as not sent';
    like $err, qr/no application fee/, 'saying the charge took no fee';
    is scalar @{ calls_of( \@calls, 'refund' ) }, 0, 'no fee refund request';
};

subtest 'invalid fee refund amount is refused' => sub {
    for my $amount ( 0, -100, 1.5, '50abc', 251 ) {
        my $payment = a_payment();
        my @calls;
        my $err = fee_refund_error( $payment, \@calls, { amount_cents => $amount },
            fee => { id => 'fee_abc123', amount => 250, amount_refunded => 50 } );

        like $err, qr/REFUND_NOT_SENT/, "amount $amount refused as not sent";
        is scalar @{ calls_of( \@calls, 'refund' ) }, 0, "amount $amount sends no fee refund";
    }
};

subtest 'charge lookup error sends no fee refund' => sub {
    my $payment = a_payment();
    my @calls;
    my $err = fee_refund_error( $payment, \@calls, {},
        intent => 'Stripe api_error: No such payment_intent' );

    like $err, qr/No such payment_intent/, 'the Stripe error surfaces';
    is scalar @{ calls_of( \@calls, 'intent' ) }, 1, 'the charge was looked up';
    is scalar @{ calls_of( \@calls, 'refund' ) }, 0, 'no fee refund request';
};

subtest 'method writes no fee column' => sub {
    my $payment = a_payment();
    $db->update( 'payments', { platform_fee_cents => 250 }, { id => $payment->id } );
    my $before = $db->select( 'payments', '*', { id => $payment->id } )->hash;

    my @calls;
    with_stripe( \@calls, sub { settle( $payment->refund_platform_fee_async($db) ) } );

    is scalar @{ calls_of( \@calls, 'refund' ) }, 1, 'the fee refund was requested';
    is_deeply $db->select( 'payments', '*', { id => $payment->id } )->hash, $before,
        'the payment row is unchanged';
};

# The decision made on the fee Stripe returns, with no Stripe call at all.
subtest 'fee refund plan' => sub {
    my $payment = a_payment();
    my $fee = sub (%over) {
        { id => 'fee_plan', charge => 'ch_plan', account => 'acct_fee_tenant',
          amount => 250, amount_refunded => 0, %over };
    };
    my $plan = sub ( $f, $charge, $asked ) { $payment->platform_fee_refund_plan( $f, $charge, $asked ) };

    is_deeply $plan->( $fee->(), 'ch_plan', 250 ), { send => 250 }, 'the recorded amount is sent';
    is_deeply $plan->( $fee->(), 'ch_plan', undef ), { send => 250 }, 'no amount sends what is left';
    is_deeply $plan->( $fee->( amount_refunded => 250 ), 'ch_plan', 250 ), { returned => 250 },
        'a fee already returned in full sends nothing';
    is_deeply $plan->( $fee->( amount_refunded => 200 ), 'ch_plan', 150 ), { send => 50 },
        'a request above what is left is capped at what is left';

    my %refused = (
        'more than the whole fee'  => [ $fee->(), 'ch_plan', 251, qr/more than the 250-cent fee/ ],
        'a fee on another charge'  => [ $fee->(), 'ch_other', 250, qr/charge/ ],
        'a fee from another account' => [ $fee->( account => 'acct_other' ), 'ch_plan', 250, qr/account/ ],
    );
    for my $case ( sort keys %refused ) {
        my ( $f, $charge, $asked, $why ) = $refused{$case}->@*;
        ok !eval { $plan->( $f, $charge, $asked ); 1 }, "refused: $case";
        like $@, qr/REFUND_NOT_SENT/, "as not sent: $case";
        like $@, $why, "saying why: $case";
    }
};

done_testing;
