#!/usr/bin/env perl
use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More;
defer { done_testing };

# Test installment payment functionality end-to-end
use Registry::PriceOps::PaymentSchedule;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::MockObject;

# Mock Stripe environment
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_mock_key_for_testing';

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

# Create test tenant and switch to tenant schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'End-to-End Test Tenant',
    slug => 'e2e_installment_test',
});
$dao->db->query('SELECT clone_schema(?)', 'e2e_installment_test');

$dao = Registry::DAO->new(url => $test_db->uri, schema => 'e2e_installment_test');
my $db = $dao->db;

subtest 'End-to-end installment payment schedule creation' => sub {
    # Create mock enrollment and pricing plan data
    my $enrollment_id = $db->insert('enrollments', {
        session_id => 1,
        student_id => 1,
        family_member_id => 1,
        status => 'active',
        metadata => '{"test": "e2e_enrollment"}'
    }, { returning => 'id' })->hash->{id};

    # Mock Stripe client for testing
    my $mock_stripe = Test::MockObject->new;
    $mock_stripe->set_always('create_installment_subscription', {
        id => 'sub_e2e_test_subscription',
        status => 'active'
    });

    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => 1, # Mock pricing plan ID
        customer_id => 'cus_e2e_test_customer',
        payment_method_id => 'pm_e2e_test_method',
        total_amount => 300.00,
        installment_count => 3,
        frequency => 'monthly'
    });

    ok $schedule, 'Payment schedule created successfully in end-to-end test';
    isa_ok $schedule, 'Registry::DAO::PaymentSchedule';
    is $schedule->enrollment_id, $enrollment_id, 'Enrollment ID matches';
    is $schedule->total_amount, '300.00', 'Total amount is correct';
    is $schedule->installment_count, 3, 'Installment count is correct';
    is $schedule->installment_amount, '100.00', 'Installment amount calculated correctly';
    is $schedule->status, 'active', 'Schedule starts as active';
    is $schedule->stripe_subscription_id, 'sub_e2e_test_subscription', 'Stripe subscription ID stored';

    # Verify scheduled payments were created
    my @scheduled_payments = $schedule->scheduled_payments($db);
    is scalar @scheduled_payments, 3, 'Three scheduled payments created';

    # Test payment schedule lifecycle
    my $suspended_schedule = $schedule_ops->suspend_schedule($db, $schedule->id, 'parent_request');
    is $suspended_schedule->status, 'suspended', 'Schedule can be suspended';

    my $reactivated_schedule = $schedule_ops->reactivate_schedule($db, $schedule->id);
    is $reactivated_schedule->status, 'active', 'Schedule can be reactivated';

    # Test marking payments as completed
    my $first_payment = $scheduled_payments[0];
    my $completed_payment = $schedule_ops->mark_payment_completed($db, $first_payment->id, 'pi_test_payment');
    is $completed_payment->status, 'paid', 'Payment can be marked as completed';
    ok defined $completed_payment->paid_at, 'Payment timestamp is set';
};

subtest 'End-to-end installment payment failure handling' => sub {
    # Create another test enrollment
    my $enrollment_id = $db->insert('enrollments', {
        session_id => 1,
        student_id => 2,
        family_member_id => 2,
        status => 'active',
        metadata => '{"test": "e2e_failure_test"}'
    }, { returning => 'id' })->hash->{id};

    # Mock Stripe client for testing
    my $mock_stripe = Test::MockObject->new;
    $mock_stripe->set_always('create_installment_subscription', {
        id => 'sub_e2e_failure_test',
        status => 'active'
    });

    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => 1, # Mock pricing plan ID
        customer_id => 'cus_e2e_failure_customer',
        payment_method_id => 'pm_e2e_failure_method',
        total_amount => 450.00,
        installment_count => 3,
        frequency => 'monthly'
    });

    ok $schedule, 'Second payment schedule created for failure testing';

    # Get a scheduled payment to test failure handling
    my @scheduled_payments = $schedule->scheduled_payments($db);
    my $test_payment = $scheduled_payments[1]; # Second payment

    # Test payment failure handling
    my $failed_payment = $schedule_ops->mark_payment_failed($db, $test_payment->id, 'card_declined');
    is $failed_payment->status, 'failed', 'Payment can be marked as failed';
    is $failed_payment->failure_reason, 'card_declined', 'Failure reason is stored';
    ok defined $failed_payment->failed_at, 'Failure timestamp is set';

    # Test retry functionality
    my $retried_payment = $schedule_ops->retry_failed_payment($db, $failed_payment->id);
    is $retried_payment->status, 'pending', 'Failed payment can be reset to pending for retry';
    ok !defined $retried_payment->failed_at, 'Failed timestamp cleared on retry';
};

subtest 'End-to-end payment schedule completion' => sub {
    # Use existing schedule from first test
    my $existing_schedule = Registry::DAO::PaymentSchedule->find($db, { status => 'active' });
    ok @$existing_schedule > 0, 'Found active payment schedule from previous test';

    my $schedule = $existing_schedule->[0];
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new;

    # Mark all payments as completed
    my @scheduled_payments = $schedule->scheduled_payments($db);
    for my $payment (@scheduled_payments) {
        if ($payment->status eq 'pending') {
            $schedule_ops->mark_payment_completed($db, $payment->id, "pi_completion_test_" . $payment->id);
        }
    }

    # Check if schedule auto-completes
    my $completed_schedule = $schedule_ops->check_completion_status($db, $schedule->id);
    is $completed_schedule->status, 'completed', 'Schedule marked as completed when all payments are paid';
};