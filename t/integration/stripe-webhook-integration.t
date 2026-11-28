#!/usr/bin/env perl
# ABOUTME: The Stripe webhook controller: its signature checks, and a session cart settled through the Connect endpoint.
# ABOUTME: The settled charge completes, records its fee, and its run's driver books the child in the seller's schema.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Registry::DAO;
use Registry::Controller::Webhooks;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;
use Registry::DAO::Tenant;
use Registry::DAO::FamilyMember;
use Registry::DAO::User;
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::SessionCheckout qw( started_charge drive );
use Registry::DAO::Payment;
use JSON;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $db = $dao->db;

subtest 'Webhook controller basic functionality' => sub {
    plan tests => 2;
    
    my $webhook_controller = Registry::Controller::Webhooks->new();
    isa_ok($webhook_controller, 'Registry::Controller::Webhooks');
    can_ok($webhook_controller, 'stripe');
};

subtest 'Webhook signature verification' => sub {
    plan tests => 4;
    
    my $webhook_controller = Registry::Controller::Webhooks->new();
    
    # Test without endpoint secret (should fail -- STRIPE_WEBHOOK_SECRET is mandatory).
    # Use a properly-formatted signature header so the failure comes from the
    # missing secret, not from header parsing.
    my $ts = time();
    my $result1 = $webhook_controller->_verify_stripe_signature('payload', "t=$ts,v1=abc123", undef);
    is($result1, 0, 'Verification fails when no secret configured');
    
    # Test with missing signature components
    my $result2 = $webhook_controller->_verify_stripe_signature('payload', 'invalid', 'secret');
    is($result2, 0, 'Verification fails with invalid signature format');
    
    # Test with old timestamp
    my $old_time = time() - 400; # 6+ minutes old
    my $old_sig = "t=$old_time,v1=signature";
    my $result3 = $webhook_controller->_verify_stripe_signature('payload', $old_sig, 'secret');
    is($result3, 0, 'Verification fails with old timestamp');
    
    # Test with recent timestamp but wrong signature
    my $recent_time = time() - 60; # 1 minute old
    my $recent_sig = "t=$recent_time,v1=wrongsignature";
    my $result4 = $webhook_controller->_verify_stripe_signature('payload', $recent_sig, 'secret');
    ok(!$result4, 'Verification fails with wrong signature');
};

# The Connect seller, at file scope so its platform terms are stated before it sells.
my $slug    = "int_conn_$$";
my $account = "acct_int_conn_$$";
my $admin = Registry::DAO::User->create($db, { username => "int_conn_admin_$$",
    email => "int_conn_admin_$$\@test.example", name => 'A', user_type => 'admin' });
Registry::DAO::Tenant->provision($db, { name => "Int Conn $$", slug => $slug,
    users => [$admin], stripe_connect_account_id => $account,
    stripe_charges_enabled => 1, stripe_details_submitted => 1 });
state_platform_terms( $db, $slug, { rate => 0 } );

subtest 'stripe webhook integration settles through connect endpoint' => sub {
    local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_integration_connect';
    local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_integration_placeholder';

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub ($c, $tenant = undef) {
        defined $tenant ? Registry::DAO->new(url => $test_db->uri, schema => $tenant) : $dao });

    my $tdao    = Registry::DAO->new(url => $test_db->uri, schema => $slug);
    my $tdb     = $tdao->db;
    my $session = make_session($tdb);
    my $version = session_offer($tdb, $session, price_cents => 12000);
    my $parent  = Registry::DAO::User->create($tdb, { username => 'int_parent',
        email => 'int_parent@test.example', name => 'P', user_type => 'parent' });
    my $child   = Registry::DAO::FamilyMember->create($tdb,
        { family_id => $parent->id, child_name => 'Int Kid', birth_date => '2018-01-01' });
    my ( $run, $pay ) = held_cart($tdao, $parent->id, [ $child->id, $session->id, $version->id, 'pay' ]);
    my $payment = started_charge($tdb, $run, $pay);
    is $payment->metadata->{stripe_account_id}, $account,
        'the sale is snapshotted onto the seller account';

    my $event_id = "evt_int_conn_$$";
    Test::Registry::StripeWebhook::post_connect($t, {
        id      => $event_id,
        type    => 'payment_intent.succeeded',
        account => $account,
        data    => { object => {
            id                     => $payment->stripe_payment_intent_id,
            amount                 => 12000,
            application_fee_amount => 360,
            metadata => { payment_id => $payment->id, tenant_slug => $slug },
        } },
    })->status_is(200);
    drive($t->app->minion);

    my $settled = Registry::DAO::Payment->find($tdb, { id => $payment->id });
    is $settled->status, 'completed', 'the payment is completed in the seller schema';
    is $settled->platform_fee_cents, 360, 'with the fee Stripe reported';
    is $tdb->select('entitlements', ['id'], { payment_id => $payment->id, holder_family_member_id => $child->id })->rows, 1,
        'and the child holds a place there';
    ok $db->select('registry.webhook_events', ['processed_at'],
        { stripe_event_id => $event_id })->hash->{processed_at},
        'the event is claimed and marked processed';
};

done_testing();