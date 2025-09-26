#!/usr/bin/env perl
use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(signatures defer);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::Project;
use Registry::DAO::Location;
use Registry::DAO::FamilyMember;
use JSON qw(encode_json decode_json);
use DateTime;

defer { done_testing };

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

# Create test data - focusing on DAO operations that admin dashboard would use
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

# Create pricing plan first
my $pricing_plan_id = $db->insert('pricing_plans', {
    session_id => $session->id,
    plan_name => 'Admin Test Plan',
    plan_type => 'standard',
    amount => 450.00,
    installments_allowed => 1
}, { returning => 'id' })->hash->{id};

# Create payment schedule
my $payment_schedule = Registry::DAO::PaymentSchedule->create($db, {
    enrollment_id => $enrollment->{id},
    pricing_plan_id => $pricing_plan_id,
    stripe_subscription_id => 'sub_admin_dashboard_test',
    total_amount => 450.00,
    installment_amount => 150.00,
    installment_count => 3,
    status => 'active'
});

# Create scheduled payments with different statuses for admin dashboard testing
my $completed_payment = Registry::DAO::ScheduledPayment->create($db, {
    payment_schedule_id => $payment_schedule->id,
    installment_number => 1,
    amount => 150.00,
    status => 'completed',
    paid_at => \"NOW() - INTERVAL '30 days'"
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
    failed_at => \"NOW() - INTERVAL '5 days'",
    failure_reason => 'card_declined'
});

subtest 'Admin dashboard payment schedule data operations' => sub {
    # Test the data operations that would be used by admin dashboard
    my $active_schedules = $db->select('registry.payment_schedules', '*', { status => 'active' })->hashes;
    ok @$active_schedules > 0, 'Can find active payment schedules';

    my $schedule = $active_schedules->[0];
    isa_ok $schedule, 'HASH';
    is $schedule->{status}, 'active', 'Schedule has active status';
    is $schedule->{total_amount}, '450.00', 'Schedule has correct total amount';
    is $schedule->{installment_count}, 3, 'Schedule has correct installment count';

    # Test finding by enrollment (for enrollment detail pages)
    my $enrollment_schedules = $db->select('registry.payment_schedules', '*', { enrollment_id => $enrollment->{id} })->hashes;
    ok @$enrollment_schedules > 0, 'Can find schedules by enrollment';

    # Test scheduled payments retrieval for dashboard display
    my $scheduled_payments = $db->select('registry.scheduled_payments', '*', { payment_schedule_id => $schedule->{id} })->hashes;
    is scalar @$scheduled_payments, 3, 'Has expected number of scheduled payments';

    # Verify payment status distribution for admin reports
    my %status_count;
    for my $payment (@$scheduled_payments) {
        $status_count{$payment->{status}}++;
    }

    is $status_count{completed}, 1, 'Has one completed payment';
    is $status_count{pending}, 1, 'Has one pending payment';
    is $status_count{failed}, 1, 'Has one failed payment';
};

subtest 'Admin dashboard payment schedule management' => sub {
    # Test status management operations that admin dashboard would perform
    my $schedule = $payment_schedule;

    # Test suspension (what admin would do for problematic accounts)
    $schedule->update_status($db, 'suspended');
    is $schedule->status, 'suspended', 'Can suspend payment schedule';

    # Test reactivation
    $schedule->update_status($db, 'active');
    is $schedule->status, 'active', 'Can reactivate payment schedule';

    # Test cancellation with all pending payments
    my $test_schedule = Registry::DAO::PaymentSchedule->create($db, {
        enrollment_id => $enrollment->{id},
        pricing_plan_id => $pricing_plan_id,
        stripe_subscription_id => 'sub_test_cancellation',
        total_amount => 300.00,
        installment_amount => 100.00,
        installment_count => 3,
        status => 'active'
    });

    # Add some pending payments
    Registry::DAO::ScheduledPayment->create($db, {
        payment_schedule_id => $test_schedule->id,
        installment_number => 1,
        amount => 100.00,
        status => 'pending'
    });

    Registry::DAO::ScheduledPayment->create($db, {
        payment_schedule_id => $test_schedule->id,
        installment_number => 2,
        amount => 100.00,
        status => 'pending'
    });

    # Test atomic cancellation
    $test_schedule->cancel_with_pending_payments($db);
    is $test_schedule->status, 'cancelled', 'Schedule is cancelled';

    # Verify pending payments were also cancelled
    my $cancelled_payments = $db->select('registry.scheduled_payments', '*', { payment_schedule_id => $test_schedule->id })->hashes;
    for my $payment (@$cancelled_payments) {
        is $payment->{status}, 'cancelled', 'Pending payment was cancelled';
    }
};

subtest 'Admin dashboard reporting data' => sub {
    # Test data aggregation operations for admin reports
    my $all_schedules = $db->select('registry.payment_schedules', '*')->hashes;
    ok @$all_schedules >= 2, 'Multiple schedules exist for reporting';

    # Calculate totals (what admin dashboard would show)
    my $total_revenue = 0;
    my $active_count = 0;
    my $cancelled_count = 0;

    for my $schedule (@$all_schedules) {
        $total_revenue += $schedule->{total_amount};
        $active_count++ if $schedule->{status} eq 'active';
        $cancelled_count++ if $schedule->{status} eq 'cancelled';
    }

    ok $total_revenue > 0, 'Can calculate total revenue across schedules';
    ok $active_count > 0, 'Has active schedules for reporting';
    ok $cancelled_count > 0, 'Has cancelled schedules for reporting';

    # Test payment failure reporting
    my $all_payments = $db->select('registry.scheduled_payments', '*')->hashes;
    my $failed_payments = [grep { $_->{status} eq 'failed' } @$all_payments];

    ok @$failed_payments > 0, 'Has failed payments for admin attention';

    my $failed_payment = $failed_payments->[0];
    ok defined $failed_payment->{failed_at}, 'Failed payment has timestamp for reporting';
    ok defined $failed_payment->{failure_reason}, 'Failed payment has reason for admin review';
};

subtest 'Admin dashboard Stripe integration data' => sub {
    # Test Stripe subscription ID tracking for admin dashboard
    my $stripe_schedules = $db->select('registry.payment_schedules', '*', { stripe_subscription_id => 'sub_admin_dashboard_test' })->hashes;
    ok @$stripe_schedules > 0, 'Can find schedules by Stripe subscription ID';

    my $schedule = $stripe_schedules->[0];
    is $schedule->{stripe_subscription_id}, 'sub_admin_dashboard_test', 'Stripe ID is properly stored';

    # This data would be used for webhook processing and admin monitoring
    ok defined $schedule->{enrollment_id}, 'Schedule is linked to enrollment';
    ok $schedule->{total_amount} > 0, 'Schedule has valid total amount';
};