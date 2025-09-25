#!/usr/bin/env perl
use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Location;
use JSON qw(encode_json decode_json);
use DateTime;

# Mock Stripe environment
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_admin_dashboard_test';

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

# Create test tenant
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Admin Dashboard Test Tenant',
    slug => 'admin_dashboard_test',
});
$dao->db->query('SELECT clone_schema(?)', 'admin_dashboard_test');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'admin_dashboard_test');
my $db = $dao->db;

# Create test application with proper configuration
my $app = Registry->new();
$app->config->{database} = { url => $test_db->uri, schema => 'admin_dashboard_test' };

# Initialize test client
my $t = Test::Mojo->new($app);

# Create test data
my $location = Registry::DAO::Location->create($db, {
    name => 'Admin Dashboard Test Location',
    address_info => {
        street_address => '789 Admin St',
        city => 'Admin City',
        state => 'AC',
        postal_code => '12345'
    },
    metadata => {}
});

my $project = Registry::DAO::Project->create($db, {
    name => 'Admin Dashboard Test Project',
    metadata => { description => 'Testing admin dashboard integration' }
});

my $session = Registry::DAO::Session->create($db, {
    name => 'Admin Dashboard Test Session',
    project_id => $project->id,
    location_id => $location->id,
    start_date => time() + 86400 * 30,
    end_date => time() + 86400 * 60,
    capacity => 20,
    status => 'published',
    metadata => {}
});

my $pricing_plan = Registry::DAO::PricingPlan->create($db, {
    session_id => $session->id,
    plan_name => 'Admin Test 3-Payment Plan',
    plan_type => 'standard',
    amount => 450.00,
    installments_allowed => 1,
    installment_count => 3
});

# Create parent and admin users
my $parent = Registry::DAO::User->create($db, {
    username => 'admin.test.parent',
    email => 'admin.test@parent.com',
    name => 'Admin Test Parent',
    password => 'password123',
    user_type => 'parent',
    stripe_customer_id => 'cus_admin_test_parent'
});

my $admin = Registry::DAO::User->create($db, {
    username => 'admin.dashboard.user',
    email => 'admin@dashboard.test',
    name => 'Admin Dashboard User',
    password => 'admin123',
    user_type => 'admin'
});

my $child = Registry::DAO::FamilyMember->create($db, {
    family_id => $parent->id,
    child_name => 'Admin Test Child',
    birth_date => '2016-03-20',
    grade => '2nd',
    medical_info => encode_json({ allergies => [] })
});

# Create enrollment with installment payment
my $enrollment = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    family_member_id => $child->id,
    status => 'active',
    metadata => encode_json({ test => 'admin_dashboard' })
}, { returning => '*' })->hash;

# Create payment schedule
my $payment_schedule = Registry::DAO::PaymentSchedule->create($db, {
    enrollment_id => $enrollment->{id},
    pricing_plan_id => $pricing_plan->id,
    stripe_subscription_id => 'sub_admin_dashboard_test',
    total_amount => 450.00,
    installment_amount => 150.00,
    installment_count => 3,
    status => 'active'
});

# Create scheduled payments with different statuses
my $paid_payment = Registry::DAO::ScheduledPayment->create($db, {
    payment_schedule_id => $payment_schedule->id,
    installment_number => 1,
    amount => 150.00,
    status => 'paid',
    paid_at => DateTime->now->subtract(days => 30)->epoch
});

my $pending_payment = Registry::DAO::ScheduledPayment->create($db, {
    payment_schedule_id => $payment_schedule->id,
    installment_number => 2,
    amount => 150.00,
    status => 'pending'
});

my $failed_payment = Registry::DAO::ScheduledPayment->create($db, {
    payment_schedule_id => $payment_schedule->id,
    installment_number => 3,
    amount => 150.00,
    status => 'failed',
    failed_at => DateTime->now->subtract(days => 5)->epoch,
    failure_reason => 'card_declined'
});

subtest 'Admin dashboard payment schedule listing' => sub {
    # Mock admin session
    my $session_data = {
        user_id => $admin->id,
        user_type => 'admin',
        username => $admin->username
    };

    # Test payment schedules overview page
    $t->get_ok('/admin/payment-schedules')
      ->status_is(200, 'Payment schedules page loads')
      ->content_like(qr/payment.*schedule/i, 'Contains payment schedule content')
      ->content_like(qr/Admin Dashboard Test Session/, 'Shows test session')
      ->content_like(qr/Admin Test Parent/, 'Shows parent name')
      ->content_like(qr/\$450\.00/, 'Shows total amount');

    # Test filtering by status
    $t->get_ok('/admin/payment-schedules?status=active')
      ->status_is(200, 'Filtered payment schedules loads')
      ->content_like(qr/active/i, 'Shows active status filter');

    # Test search functionality
    $t->get_ok('/admin/payment-schedules?search=Admin+Test+Parent')
      ->status_is(200, 'Search results load')
      ->content_like(qr/Admin Test Parent/, 'Search returns matching results');
};

subtest 'Admin dashboard individual payment schedule details' => sub {
    # Test individual payment schedule view
    $t->get_ok("/admin/payment-schedules/" . $payment_schedule->id)
      ->status_is(200, 'Payment schedule detail page loads')
      ->content_like(qr/installment.*details/i, 'Contains installment details')
      ->content_like(qr/Admin Test Child/, 'Shows child name')
      ->content_like(qr/3.*installments/i, 'Shows installment count')
      ->content_like(qr/\$150\.00/, 'Shows installment amount');

    # Check that all payment statuses are displayed
    my $content = $t->tx->res->body;
    like $content, qr/paid/i, 'Shows paid status';
    like $content, qr/pending/i, 'Shows pending status';
    like $content, qr/failed/i, 'Shows failed status';
    like $content, qr/card_declined/i, 'Shows failure reason';
};

subtest 'Admin dashboard payment schedule management actions' => sub {
    # Test payment schedule suspension
    $t->post_ok("/admin/payment-schedules/" . $payment_schedule->id . "/suspend",
                form => { reason => 'Parent request' })
      ->status_is(302, 'Suspension request redirects')
      ->header_like('Location', qr{/admin/payment-schedules}, 'Redirects back to schedules');

    # Verify schedule was suspended
    my $suspended_schedule = Registry::DAO::PaymentSchedule->new(id => $payment_schedule->id)->load($db);
    is $suspended_schedule->status, 'suspended', 'Payment schedule suspended';

    # Test payment schedule reactivation
    $t->post_ok("/admin/payment-schedules/" . $payment_schedule->id . "/reactivate")
      ->status_is(302, 'Reactivation request redirects')
      ->header_like('Location', qr{/admin/payment-schedules}, 'Redirects back to schedules');

    # Verify schedule was reactivated
    my $reactivated_schedule = Registry::DAO::PaymentSchedule->new(id => $payment_schedule->id)->load($db);
    is $reactivated_schedule->status, 'active', 'Payment schedule reactivated';

    # Test manual payment retry for failed payment
    $t->post_ok("/admin/scheduled-payments/" . $failed_payment->id . "/retry")
      ->status_is(302, 'Payment retry request redirects')
      ->header_like('Location', qr{/admin/payment-schedules}, 'Redirects appropriately');

    # Note: Actual retry processing would require Stripe integration
    # In a real test, we'd verify the retry was queued or attempted
};

subtest 'Admin dashboard payment schedule reporting' => sub {
    # Test payment schedule summary statistics
    $t->get_ok('/admin/reports/payment-schedules')
      ->status_is(200, 'Payment schedule reports load')
      ->content_like(qr/total.*revenue/i, 'Shows revenue metrics')
      ->content_like(qr/installment.*performance/i, 'Shows installment metrics');

    # Test CSV export functionality
    $t->get_ok('/admin/reports/payment-schedules/export?format=csv')
      ->status_is(200, 'CSV export works')
      ->header_is('Content-Type' => 'text/csv; charset=UTF-8', 'Correct CSV content type')
      ->content_like(qr/payment_schedule_id/, 'Contains CSV headers')
      ->content_like(qr/Admin Test Parent/, 'Contains test data');

    # Test date range filtering in reports
    my $start_date = DateTime->now->subtract(days => 60)->ymd;
    my $end_date = DateTime->now->add(days => 30)->ymd;

    $t->get_ok("/admin/reports/payment-schedules?start_date=$start_date&end_date=$end_date")
      ->status_is(200, 'Date-filtered reports load')
      ->content_like(qr/\$450\.00/, 'Shows test payment in date range');
};

subtest 'Admin dashboard payment failure notifications' => sub {
    # Test payment failure dashboard alerts
    $t->get_ok('/admin/dashboard')
      ->status_is(200, 'Admin dashboard loads')
      ->content_like(qr/payment.*failures?/i, 'Shows payment failure alerts')
      ->content_like(qr/requires.*attention/i, 'Shows attention needed alerts');

    # Test failed payments management page
    $t->get_ok('/admin/payment-failures')
      ->status_is(200, 'Payment failures page loads')
      ->content_like(qr/failed.*payments/i, 'Shows failed payments heading')
      ->content_like(qr/card_declined/, 'Shows failure reason')
      ->content_like(qr/retry.*payment/i, 'Shows retry options');

    # Test bulk actions for failed payments
    $t->post_ok('/admin/payment-failures/bulk-retry',
                form => {
                    payment_ids => $failed_payment->id,
                    action => 'retry'
                })
      ->status_is(302, 'Bulk retry redirects')
      ->header_like('Location', qr{payment-failures}, 'Redirects to failures page');
};

subtest 'Admin dashboard customer communication' => sub {
    # Test payment reminder functionality
    $t->get_ok("/admin/payment-schedules/" . $payment_schedule->id . "/communicate")
      ->status_is(200, 'Communication page loads')
      ->content_like(qr/send.*reminder/i, 'Shows reminder options')
      ->content_like(qr/Admin Test Parent/, 'Shows parent information')
      ->content_like(qr/email.*notification/i, 'Shows notification options');

    # Test sending payment reminder
    $t->post_ok("/admin/payment-schedules/" . $payment_schedule->id . "/send-reminder",
                form => {
                    message_type => 'payment_reminder',
                    custom_message => 'Your next payment is due soon.'
                })
      ->status_is(302, 'Reminder sending redirects')
      ->header_like('Location', qr{payment-schedules}, 'Redirects appropriately');

    # In a real implementation, we'd verify the email was queued/sent
    # For this test, we just verify the endpoint works
};

subtest 'Admin dashboard integration with existing enrollment management' => sub {
    # Test that payment schedule information appears on enrollment details
    $t->get_ok("/admin/enrollments/" . $enrollment->{id})
      ->status_is(200, 'Enrollment details load')
      ->content_like(qr/payment.*schedule/i, 'Shows payment schedule info')
      ->content_like(qr/3.*installments/i, 'Shows installment details')
      ->content_like(qr/\$150\.00/, 'Shows installment amount');

    # Test enrollment status changes affect payment schedules appropriately
    $t->post_ok("/admin/enrollments/" . $enrollment->{id} . "/status",
                form => { status => 'withdrawn' })
      ->status_is(302, 'Enrollment status change redirects');

    # In a real implementation, we'd verify that changing enrollment status
    # to withdrawn would suspend the payment schedule
    # For this test, we just verify the integration point exists
};

done_testing;