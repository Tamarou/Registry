#!/usr/bin/env perl
# ABOUTME: The payer's enrollment_confirmation after a paid session cart: each child, session, days in the location's zone,
# ABOUTME: price, plan with its due dates and the policies, in one email sent once when the checkout completes.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Fixtures;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::Offers qw( instalment_plan );
use Test::Registry::SessionCheckout qw( started_charge post_succeeded drive );
use Email::Sender::Simple;
use Registry::DAO::FamilyMember;
use Registry::DAO::Notification;
use Registry::DAO::Payment;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_placeholder_checkout_confirmation';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_checkout_confirmation';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_checkout_confirmation_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => '0.025' } );

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) { $dao } );

my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'scc_parent', name => 'Pat Payer',
    email => 'scc_parent@test.example' } );
my ( $kid, $sib ) = map {
    Registry::DAO::FamilyMember->create( $db, { family_id => $parent->id, child_name => $_, birth_date => '2016-01-01' } )
} qw( Kiddo Sibling );

# Three days from 2027-06-07, 09:00 in Los Angeles; Kiddo pays $300 once,
# Sibling $270 in three weekly parts of $90.
my $session = make_session( $db, time_zone => 'America/Los_Angeles' );
my $once    = session_offer( $db, $session, price_cents => 30000 );
my $parts   = session_offer( $db, $session, price_cents => 27000,
    policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'end' } },
    payment_plans => [ instalment_plan( id => 'parts', count => 3, cadence => 'weekly' ) ] );
my ( $run, $pay ) = held_cart( $dao, $parent->id,
    [ $kid->id, $session->id, $once->id, 'pay' ], [ $sib->id, $session->id, $parts->id, 'parts' ] );
my $payment = started_charge( $db, $run, $pay );
post_succeeded( $t, $payment, 'acct_platform_test' )->status_is(200);
drive( $t->app->minion );

sub confirmations () {
    $db->query( q{SELECT id FROM notifications WHERE user_id = ? AND type = 'enrollment_confirmation'}, $parent->id )
        ->arrays->flatten->to_array;
}

subtest 'the confirmation names both children and the three due dates' => sub {
    my $ids = confirmations();
    is scalar @$ids, 1, 'one confirmation for the cart' or return;

    Email::Sender::Simple->default_transport->clear_deliveries;
    Registry::DAO::Notification->find( $db, { id => $ids->[0] } )->send($db);
    my ($sent) = Email::Sender::Simple->default_transport->deliveries;
    ok $sent, 'sent to the payer' or return;
    is_deeply $sent->{successes}, ['scc_parent@test.example'], 'at their address';
    my $body = $sent->{email}->as_string;

    like $body, qr/Kiddo/, 'it names the first child';
    like $body, qr/Sibling/, 'and the second';
    my $line = Registry::DAO::Payment->find( $db, { id => $payment->id } )->metadata->{lines}[1];
    my @due  = map { $_->{due_date} } $line->{parts}->@*;
    is scalar @due, 3, 'three parts stored';
    like $body, qr/\Q$_\E/, "and due date $_" for @due;
};

subtest "the confirmation gives each session's days in its location's zone, its price and policies" => sub {
    my $text = Registry::DAO::Notification->find( $db, { id => confirmations()->[0] } )->message;
    like $text, qr{Kiddo: Session \d+, 2027-06-07 to 2027-06-09, from 09:00 \(America/Los_Angeles\)\. \$300\.00, paid in full\.},
        "Kiddo's session, days and local start, and the price paid";
    like $text, qr{Sibling: .*\$270\.00 in 3 payments: \$90\.00 paid \S+, \$90\.00 due \S+, \$90\.00 due \S+\.},
        "Sibling's plan, each part with its date";
    like $text, qr/Sales are final\./, 'with the policies sold under';
};

done_testing;
