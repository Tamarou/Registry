#!/usr/bin/env perl
# ABOUTME: Test for race condition prevention in payment schedule completion
# ABOUTME: Verifies that concurrent payment completions are handled atomically
use v5.34.0;
use warnings;
use experimental 'signatures';
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::PriceOps::PaymentSchedule;
use Registry::PriceOps::ScheduledPayment;
use DateTime;

# Mock Stripe environment for testing
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_mock_key_for_testing';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Race Condition Tenant',
    slug => 'test_race_condition',
});
$dao->db->query('SELECT clone_schema(?)', 'test_race_condition');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_race_condition');
my $db = $dao->db;

# Create test data
my $location = Registry::DAO::Location->create($db, {
    name => 'Test Location',
    address_info => {
        street_address => '123 Main St',
        city => 'Test City',
        state => 'TS',
        postal_code => '12345'
    },
    metadata => {}
});

my $teacher = Registry::DAO::User->create($db, {
    name => 'Test Teacher',
    username => 'testteacher_race',
    email => 'teacher_race@test.com',
    user_type => 'staff'
});

my $project = Registry::DAO::Project->create($db, {
    name => 'Test Project',
    metadata => {}
});

my $event = Registry::DAO::Event->create($db, {
    time => '2024-07-01 10:00:00',
    duration => 120,
    location_id => $location->id,
    project_id => $project->id,
    teacher_id => $teacher->id,
    metadata => {},
    capacity => 20
});

my $session = Registry::DAO::Session->create($db, {
    name => 'Test Session',
    start_date => '2024-07-02',
    end_date => '2024-07-09',
    status => 'published',
    metadata => {}
});

# Link event to session
$session->add_events($db, $event->id);

# Create pricing plan that allows installments
my $pricing_plan = Registry::DAO::PricingPlan->create($db, {
    session_id => $session->id,
    plan_name => 'Installment Plan',
    plan_type => 'standard',
    amount => 300.00,
    installments_allowed => 1,  # true
    installment_count => 3
});

# Create test parent user for enrollment
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent_race@example.com',
    username => 'testparent_race',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent'
});

subtest 'Concurrent payment completion race condition prevention' => sub {
    # Create payment schedule with 3 installments
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new();
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => '550e8400-e29b-41d4-a716-446655440000',  # Mock enrollment ID
        pricing_plan_id => $pricing_plan->id,
        total_amount => 300.00,
        installment_count => 3,
        first_payment_date => '2024-01-01',
    });

    ok($schedule, 'Payment schedule created');
    is($schedule->status, 'active', 'Schedule is active');

    # Get all scheduled payments
    my @payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    is(@payments, 3, 'Three scheduled payments created');

    # Mark first payment as completed (no race condition here)
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new();
    my $result1 = $payment_ops->mark_payment_completed($db, $payments[0]);
    ok($result1->{success}, 'First payment marked completed');
    is($result1->{schedule_completed}, 0, 'Schedule not completed after first payment');

    # Reload schedule to check status
    $schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is($schedule->status, 'active', 'Schedule still active after first payment');

    # Simulate race condition: two processes completing the last two payments simultaneously
    # We'll use separate database connections to simulate concurrent access
    my $dao2 = Registry::DAO->new(url => $test_db->uri, schema => 'test_race_condition');
    my $db2 = $dao2->db;

    # Mark second payment as completed in first connection
    my $result2 = $payment_ops->mark_payment_completed($db, $payments[1]);
    ok($result2->{success}, 'Second payment marked completed');

    # Mark third payment as completed in second connection (simulating race)
    # Reload the payment object in the second connection
    my $payment3 = Registry::DAO::ScheduledPayment->find($db2, { id => $payments[2]->id });
    my $payment_ops2 = Registry::PriceOps::ScheduledPayment->new();
    my $result3 = $payment_ops2->mark_payment_completed($db2, $payment3);
    ok($result3->{success}, 'Third payment marked completed');

    # Only one of them should have marked the schedule as completed
    my $completed_count = ($result2->{schedule_completed} ? 1 : 0) +
                         ($result3->{schedule_completed} ? 1 : 0);
    is($completed_count, 1, 'Exactly one payment marked the schedule as completed');

    # Verify final schedule status
    $schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is($schedule->status, 'completed', 'Schedule is completed');

    # Verify all payments are completed
    my @final_payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    my @completed = grep { $_->status eq 'completed' } @final_payments;
    is(@completed, 3, 'All three payments are completed');
};

subtest 'Idempotency - marking already completed payment' => sub {
    # Create another schedule
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new();
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => '660e8400-e29b-41d4-a716-446655440001',  # Mock enrollment ID
        pricing_plan_id => $pricing_plan->id,
        total_amount => 100.00,
        installment_count => 2,
        first_payment_date => '2024-02-01',
    });

    my @payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    is(@payments, 2, 'Two scheduled payments created');

    # Mark both payments as completed
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new();
    $payment_ops->mark_payment_completed($db, $payments[0]);
    my $result = $payment_ops->mark_payment_completed($db, $payments[1]);

    ok($result->{success}, 'Second payment marked completed');
    is($result->{schedule_completed}, 1, 'Schedule marked as completed');

    # Verify schedule is completed
    $schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is($schedule->status, 'completed', 'Schedule is completed');

    # Try to complete the first payment again (should throw error as designed)
    # Reload payment to get fresh status
    my $completed_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payments[0]->id });
    eval {
        $payment_ops->mark_payment_completed($db, $completed_payment);
    };
    like($@, qr/Payment already processed/, 'Cannot mark already completed payment');
};

subtest 'Schedule already completed by another transaction' => sub {
    # Create a schedule with 2 payments
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new();
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => '770e8400-e29b-41d4-a716-446655440002',
        pricing_plan_id => $pricing_plan->id,
        total_amount => 200.00,
        installment_count => 2,
        first_payment_date => '2024-03-01',
    });

    my @payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    is(@payments, 2, 'Two payments created');

    # Complete first payment
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new();
    my $result1 = $payment_ops->mark_payment_completed($db, $payments[0]);
    ok($result1->{success}, 'First payment completed');

    # Manually mark schedule as completed (simulating another process)
    $db->query(
        'UPDATE registry.payment_schedules SET status = ? WHERE id = ?',
        'completed', $schedule->id
    );

    # Now complete second payment - should handle gracefully
    my $result2 = $payment_ops->mark_payment_completed($db, $payments[1]);
    ok($result2->{success}, 'Payment marked completed even though schedule already complete');
    is($result2->{schedule_completed}, 0, 'Schedule was already completed');
};

done_testing();