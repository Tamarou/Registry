#!/usr/bin/env perl

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;

use Registry::DAO;
use Registry::Controller::Webhooks;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;
use Registry::DAO::Tenant;
use Registry::DAO::Family;
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

subtest 'Integration with subscription DAO' => sub {
    plan tests => 3;

    use Registry::DAO::Subscription;
    
    my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
    
    # Create test tenant
    my $tenant_result = $db->query(
        'INSERT INTO registry.tenants (name, slug, stripe_customer_id, stripe_subscription_id) VALUES (?, ?, ?, ?) RETURNING id',
        'Integration Test Org', 'integration-test', 'cus_integration123', 'sub_integration456'
    );
    my $tenant_id = $tenant_result->hash->{id};
    
    # Test full webhook event processing flow
    my $event_data = {
        object => {
            id => 'sub_integration456',
            status => 'active',
            metadata => { tenant_id => $tenant_id },
            trial_end => time() + 86400  # 1 day from now
        }
    };
    
    # Process the webhook event
    my $result = $subscription_dao->process_webhook_event(
        $db,
        'evt_integration789',
        'customer.subscription.updated',
        $event_data
    );
    
    ok($result, 'Webhook event processed successfully');
    
    # Verify tenant status was updated
    my $updated_tenant = $db->query(
        'SELECT billing_status FROM registry.tenants WHERE id = ?',
        $tenant_id
    )->hash;
    
    is($updated_tenant->{billing_status}, 'active', 'Tenant billing status updated correctly');
    
    # Verify event was logged
    my $logged_event = $db->query(
        'SELECT processing_status FROM registry.subscription_events WHERE stripe_event_id = ?',
        'evt_integration789'
    )->hash;
    
    is($logged_event->{processing_status}, 'processed', 'Event logged with correct status');
};

subtest 'stripe webhook integration settles through connect endpoint' => sub {
    local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_integration_connect';

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });

    my $slug    = "int_conn_$$";
    my $account = "acct_int_conn_$$";
    my $admin = Registry::DAO::User->create($db, { username => "int_conn_admin_$$",
        email => "int_conn_admin_$$\@test.example", name => 'A', user_type => 'admin' });
    Registry::DAO::Tenant->provision($db, { name => "Int Conn $$", slug => $slug,
        users => [$admin], stripe_connect_account_id => $account,
        stripe_charges_enabled => 1, stripe_details_submitted => 1 });
    my $tdb = Registry::DAO->new(url => $test_db->uri, schema => $slug)->db;

    my $loc = Registry::DAO::Location->create($tdb, { name => 'Int Studio',
        slug => 'int-studio', address_info => {}, metadata => {} });
    my $prog = Registry::DAO::Project->create($tdb, { name => 'Int Camp',
        status => 'published', program_type_slug => 'summer-camp', metadata => {} });
    my $teacher = Registry::DAO::User->create($tdb, { username => 'int_teacher',
        email => 'int_teacher@test.example', name => 'T', user_type => 'staff' });
    my $session = Registry::DAO::Session->create($tdb, { name => 'Int Week',
        start_date => '2026-07-01', end_date => '2026-07-31',
        status => 'published', capacity => 10, metadata => {} });
    my $event = Registry::DAO::Event->create($tdb, { time => '2026-07-01 10:00:00',
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {} });
    $session->add_events($tdb, $event->id);
    my $parent = Registry::DAO::User->create($tdb, { username => 'int_parent',
        email => 'int_parent@test.example', name => 'P', user_type => 'parent' });
    my $child = Registry::DAO::Family->add_child($tdb, $parent->id, {
        child_name => 'Int Kid', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });

    my $payment = Registry::DAO::Payment->create($tdb, {
        user_id => $parent->id, amount_cents => 12000, status => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => $slug } });
    is $payment->metadata->{stripe_account_id}, $account,
        'the sale is snapshotted onto the seller account';

    my $event_id = "evt_int_conn_$$";
    Test::Registry::StripeWebhook::post_connect($t, {
        id      => $event_id,
        type    => 'payment_intent.succeeded',
        account => $account,
        data    => { object => {
            id                     => "pi_int_conn_$$",
            amount                 => 12000,
            application_fee_amount => 360,
            metadata => { payment_id => $payment->id, tenant_slug => $slug },
        } },
    })->status_is(200);

    my $settled = Registry::DAO::Payment->find($tdb, { id => $payment->id });
    is $settled->status, 'completed', 'the payment is completed in the seller schema';
    is $settled->platform_fee_cents, 360, 'with the fee Stripe reported';
    is $tdb->select('enrollments', ['id'], { payment_id => $payment->id })->rows, 1,
        'and the child is enrolled there';
    ok $db->select('registry.webhook_events', ['processed_at'],
        { stripe_event_id => $event_id })->hash->{processed_at},
        'the event is claimed and marked processed';
};

done_testing();