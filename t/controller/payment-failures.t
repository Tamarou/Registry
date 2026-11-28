#!/usr/bin/env perl
# ABOUTME: A session cart's charge that fails or is still processing when the parent returns from Stripe.
# ABOUTME: Nothing is booked, the seats stay held, and the payment row records what Stripe said.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows days_from_now );
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => 0 } );
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

my $t = Test::Registry::Mojo->new('Registry');
$t->ua->max_redirects(5);
my $parent = Test::Registry::Fixtures::create_user( $dao, { username => 'pf_parent', name => 'Payment Parent',
    email => 'pf@example.com', user_type => 'parent' } );
authenticate_as( $t, $parent );
my $kids = 0;

# A cart whose card form is showing: the run and its payment.
sub started_cart () {
    my $kid = Registry::DAO::FamilyMember->create( $db, {
        family_id => $parent->id, child_name => 'Kid ' . ++$kids, birth_date => '2016-01-01' } );
    my $s = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my ( $run, $pay ) = held_cart( $dao, $parent->id,
        [ $kid->id, $s->id, session_offer( $db, $s, price_cents => 30000 )->id, 'pay' ] );
    my $payment = $pay->owed_payment( $db, $run )->{payment};
    $payment->_record_intent( $db, { id => "pi_pf_$kids", client_secret => 's' } );
    return ( $run, Registry::DAO::Payment->find( $db, { id => $payment->id } ) );
}

# The parent's return from Stripe with the intent in $status.
sub returned ( $run, $payment, %intent ) {
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $s, $id ) {
        Mojo::Promise->resolve( { id => $id, amount => 30000, metadata => { payment_id => $payment->id }, %intent } );
    };
    return $t->get_ok( "/session-checkout/@{[ $run->id ]}/payment?payment_intent=" . $payment->stripe_payment_intent_id );
}

sub nothing_booked ( $run, $payment ) {
    is $db->query( 'SELECT count(*) FROM entitlements WHERE payment_id = ?', $payment->id )->array->[0], 0,
        'nothing is booked';
    is $db->query( q{SELECT count(*) FROM holds WHERE workflow_run_id = ? AND state = 'held'}, $run->id )->array->[0], 1,
        'the seat stays held';
    is Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->next_step($db)->slug, 'payment',
        'and the run waits at its payment';
}

subtest 'a declined card fails the payment with its reason' => sub {
    my ( $run, $payment ) = started_cart();
    returned( $run, $payment, status => 'requires_payment_method',
        last_payment_error => { message => 'Your card has insufficient funds.' } )
        ->status_is(200)->content_like( qr/Your card has insufficient funds\./, 'the parent is told why' );

    my $row = Registry::DAO::Payment->find( $db, { id => $payment->id } );
    is $row->status, 'failed', 'the payment is failed';
    is $row->error_message, 'Your card has insufficient funds.', "with Stripe's reason";
    nothing_booked( $run, $payment );
};

subtest 'a charge still processing is waited on' => sub {
    my ( $run, $payment ) = started_cart();
    returned( $run, $payment, status => 'processing' )
        ->status_is(200)->content_like( qr/Payment is being processed/, 'the parent is told to wait' );

    is Registry::DAO::Payment->find( $db, { id => $payment->id } )->status, 'processing', 'the payment is processing';
    nothing_booked( $run, $payment );
};

done_testing;
