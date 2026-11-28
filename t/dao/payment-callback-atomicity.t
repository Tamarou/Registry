#!/usr/bin/env perl
# ABOUTME: The parent-return callback settles a session cart's charge under the payment row's lock, in one transaction.
# ABOUTME: The payment step only settles the charge; the children's entitlements are completion's, the next step.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::Async qw( settle );
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::Service::Stripe;
use Mojo::Promise;
use Mojo::Pg;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_callback_atomicity';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
my $platform = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $platform );
state_platform_terms( $db, $platform, { rate => 0 } );
my $uri = $test_db->uri;

my $parent = Test::Registry::Fixtures::create_user( $db, {
    username => 'cb_parent', name => 'CB Parent', email => 'cb@test.local' } );
my $kids = 0;

# A one-child cart whose charge was started: its payment row stores the
# intent Registry created, as the step leaves it when the card form is shown.
sub started_cart () {
    my $kid = Registry::DAO::FamilyMember->create( $db, {
        family_id => $parent->id, child_name => 'CB Kid ' . ++$kids, birth_date => '2018-01-01' } );
    my $session = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my ( $run, $step ) = held_cart( $dao, $parent->id,
        [ $kid->id, $session->id, session_offer( $db, $session, price_cents => 10000 )->id, 'pay' ] );
    my $payment = $step->owed_payment( $db, $run )->{payment};
    $payment->_record_intent( $db, { id => 'pi_cb_' . $payment->id, client_secret => 's' } );
    return ( $run, $step, Registry::DAO::Payment->find( $db, { id => $payment->id } ) );
}

# The real _apply_intent runs against this: only the network call is faked.
sub intent_for ($payment) {
    return {
        id             => 'pi_cb_' . $payment->id,
        status         => 'succeeded',
        amount         => 10000,
        payment_method => 'pm_cb_test',
        metadata       => { payment_id => $payment->id },
    };
}

sub status_of ($payment) { Registry::DAO::Payment->find( $db, { id => $payment->id } )->status }

subtest 'a clean return completes the payment and hands the run on' => sub {
    my ( $run, $step, $payment ) = started_cart();

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( intent_for($payment) ) };

    my $result = settle( $run->process( $db, $step, { payment_intent_id => 'pi_cb_' . $payment->id } ) );

    ok !$result->{errors}, 'no refusal' or diag explain $result;
    is status_of($payment), 'completed', 'payment is completed';
    is Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->latest_step($db)->slug, 'payment',
        'the run is past its payment';
    is $db->query( 'SELECT count(*) FROM entitlements WHERE payment_id = ?', $payment->id )->array->[0], 0,
        'the payment step grants nothing itself';
};

subtest 'a failure inside the settlement rolls the completed-write back' => sub {
    my ( $run, $step, $payment ) = started_cart();

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( intent_for($payment) ) };
    # Fails after mark_completed, inside the transaction it shares.
    local *Registry::DAO::Payment::record_platform_fee =
        sub { die "probe: failed after the completed-write\n" };

    my $died = !eval { settle( $step->handle_payment_callback( $db, $run,
        { payment_intent_id => 'pi_cb_' . $payment->id } ) ); 1 };

    ok $died, 'the callback surfaces the failure rather than swallowing it';
    is status_of($payment), 'pending', 'the completed-write is rolled back with it';
};

subtest 'the settlement holds the payment row while it decides' => sub {
    # Probed from inside the real settlement, at the seam right after the lock
    # is taken and before anything writes the row: if _lock_and_refresh does
    # its job, a second backend cannot take the row.
    my ( $run, $step, $payment ) = started_cart();
    my $payment_locked;

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( intent_for($payment) ) };

    my $real_lock = \&Registry::DAO::Payment::_lock_and_refresh;
    local *Registry::DAO::Payment::_lock_and_refresh = sub ( $self, $ldb ) {
        my $out = $real_lock->( $self, $ldb );
        # NOWAIT turns "would block" into an immediate error, so a held row
        # cannot hang the suite. //= : only the first look is at the clean seam.
        $payment_locked //= !eval {
            Mojo::Pg->new($uri)->db->query( 'SELECT id FROM registry.payments WHERE id = ? FOR UPDATE NOWAIT',
                $payment->id );
            1;
        };
        return $out;
    };

    settle( $step->handle_payment_callback( $db, $run, { payment_intent_id => 'pi_cb_' . $payment->id } ) );

    ok $payment_locked, 'the payment row is held by the settlement, not merely read';
    is status_of($payment), 'completed', 'and the settlement completes';
};

done_testing;
