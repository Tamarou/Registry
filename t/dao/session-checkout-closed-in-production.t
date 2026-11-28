#!/usr/bin/env perl
# ABOUTME: The session cart's charge is refused in production before any write, until the camp and after-school milestone lands.
# ABOUTME: perigrin, 2026-11-26: camp checkout stays closed until it is on PriceOps; development and test stay open.
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
use Test::Registry::Async qw( settle );
use Mojo::Promise;
use Registry::DAO::FamilyMember;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::Service::Stripe;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => '0.025' } );
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'closed_parent', name => 'Closed Parent',
    email => 'closed_parent@test.example' } );
my $kid = Registry::DAO::FamilyMember->create( $db, { family_id => $parent->id, child_name => 'Kid', birth_date => '2016-01-01' } );

# A cart of one child, held and owing, and its payment step.
sub held () {
    my $s = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    return held_cart( $dao, $parent->id, [ $kid->id, $s->id, session_offer( $db, $s, price_cents => 30000 )->id, 'pay' ] );
}

subtest 'development and test do not refuse' => sub {
    for my $mode (qw( development test )) {
        is Registry::DAO::WorkflowSteps::Payment->camp_checkout_refusal($mode), undef, "$mode is open";
        my ( $run, $pay ) = held();
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async =
            sub { Mojo::Promise->resolve( { id => "pi_open_$mode", client_secret => 's' } ) };
        my $out = do { local $ENV{MOJO_MODE} = $mode; settle( $run->process( $db, $pay, {} ) ) };
        ok !$out->{errors}, "in $mode the card form is offered" or diag explain $out;
    }
    local $ENV{MOJO_MODE};
    local $ENV{PLACK_ENV};
    is Registry::DAO::WorkflowSteps::Payment->camp_checkout_refusal(), undef,
        'no mode set is development, as Mojolicious reads it';
};

done_testing;
