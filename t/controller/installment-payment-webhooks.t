#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::MockObject;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Program;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::PriceOps::PaymentSchedule;
use Registry::PriceOps::ScheduledPayment;
use Registry::Controller::Webhooks;
use JSON;
use DateTime;

# Mock Stripe environment for testing
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_mock_key_for_testing';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Installment Webhooks Tenant',
    slug => 'test_installment_webhooks',
});
$dao->db->query('SELECT clone_schema(?)', 'test_installment_webhooks');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_installment_webhooks');
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
    username => 'testteacher',
    email => 'teacher@test.com',
    user_type => 'staff'
});

my $program = Registry::DAO::Program->create($db, {
    name => 'Test Program',
    metadata => {}
});

my $event = Registry::DAO::Event->create($db, {
    time => '2024-07-01 10:00:00',
    duration => 120,
    location_id => $location->id,
    project_id => $program->id,
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
    installments_allowed => 1,
    installment_count => 3
});

# Create test parent user with Stripe customer ID
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent',
    stripe_customer_id => 'cus_test_mock_customer'
});

# Create a mock enrollment
my $enrollment_id = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    status => 'pending',
    metadata => '{"test": "enrollment"}'
}, { returning => 'id' })->hash->{id};

# Mock Stripe client for testing
my $mock_stripe = Test::MockObject->new;
$mock_stripe->set_always('create_installment_subscription', {
    id => 'sub_test_mock_subscription',
    status => 'active'
});

# Create payment schedule for webhook testing
my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
my $schedule = $schedule_ops->create_for_enrollment($db, {
    enrollment_id => $enrollment_id,
    pricing_plan_id => $pricing_plan->id,
    customer_id => 'cus_test_mock_customer',
    payment_method_id => 'pm_test_mock_payment_method',
    total_amount => 300.00,
    installment_count => 3
});

subtest 'Installment payment webhook business logic' => sub {
    # Test the business logic directly through PriceOps instead of controller
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;

    # Verify we can identify payment schedules by subscription ID
    my $found_schedule = Registry::DAO::PaymentSchedule->find($db, {
        stripe_subscription_id => 'sub_test_mock_subscription'
    });

    ok $found_schedule, 'Can find payment schedule by Stripe subscription ID';
    is $found_schedule->id, $schedule->id, 'Found the correct payment schedule';

    # Test that we can process webhook-style invoice data
    my $mock_invoice = {
        id => 'in_test_business_logic',
        subscription => 'sub_test_mock_subscription',
        payment_intent => 'pi_test_business_logic',
        status => 'paid'
    };

    my $result = $payment_ops->handle_invoice_paid($db, $mock_invoice);
    ok $result->{success}, 'Business logic processes invoice paid successfully';
};

subtest 'Invoice paid webhook processing' => sub {
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;

    # Create separate payment schedule for this test
    my $test_schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_paid_webhook',
        payment_method_id => 'pm_test_paid_webhook',
        total_amount => 200.00,
        installment_count => 2
    });

    # Mock stripe for this test schedule
    $mock_stripe->set_always('create_installment_subscription', {
        id => 'sub_test_paid_webhook',
        status => 'active'
    });

    # Create invoice.paid event data
    my $invoice_data = {
        id => 'in_test_webhook_paid',
        subscription => 'sub_test_paid_webhook',
        payment_intent => 'pi_test_webhook_paid',
        status => 'paid'
    };

    # Update test schedule subscription ID to match
    $test_schedule->update($db, { stripe_subscription_id => 'sub_test_paid_webhook' });

    # Get initial payment state
    my @payments = $test_schedule->scheduled_payments($db);
    my $first_payment = $payments[0];
    is $first_payment->status, 'pending', 'Payment starts as pending';

    # Process webhook via business logic
    my $result = $payment_ops->handle_invoice_paid($db, $invoice_data);
    ok $result->{success}, 'Invoice paid webhook processed successfully';

    # Verify payment status updated
    my $updated_payment = Registry::DAO::ScheduledPayment->find($db, { id => $first_payment->id });
    is $updated_payment->status, 'completed', 'Payment marked as completed via webhook';
    ok $updated_payment->paid_at, 'Paid timestamp set';
};

subtest 'Invoice payment failed webhook processing' => sub {
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;

    # Create separate payment schedule for this test
    my $failed_schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_failed_webhook',
        payment_method_id => 'pm_test_failed_webhook',
        total_amount => 150.00,
        installment_count => 2
    });

    # Mock stripe for this test schedule
    $mock_stripe->set_always('create_installment_subscription', {
        id => 'sub_test_failed_webhook',
        status => 'active'
    });

    # Create invoice.payment_failed event data
    my $invoice_data = {
        id => 'in_test_webhook_failed',
        subscription => 'sub_test_failed_webhook',
        payment_intent => 'pi_test_webhook_failed',
        status => 'open',
        last_finalization_error => {
            message => 'Your card was declined.'
        }
    };

    # Update test schedule subscription ID to match
    $failed_schedule->update($db, { stripe_subscription_id => 'sub_test_failed_webhook' });

    # Get initial payment state
    my @payments = $failed_schedule->scheduled_payments($db);
    my $first_payment = $payments[0];
    is $first_payment->status, 'pending', 'Payment starts as pending';

    # Process webhook via business logic
    my $result = $payment_ops->handle_invoice_payment_failed($db, $invoice_data);
    ok $result->{success}, 'Invoice payment failed webhook processed successfully';

    # Verify payment status updated
    my $updated_payment = Registry::DAO::ScheduledPayment->find($db, { id => $first_payment->id });
    is $updated_payment->status, 'failed', 'Payment marked as failed via webhook';
    ok $updated_payment->failed_at, 'Failed timestamp set';
    is $updated_payment->failure_reason, 'Your card was declined.', 'Failure reason recorded';
};

subtest 'Webhook event idempotency' => sub {
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;

    # Create separate payment schedule for idempotency test
    my $dup_schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_duplicate_webhook',
        payment_method_id => 'pm_test_duplicate_webhook',
        total_amount => 100.00,
        installment_count => 2
    });

    # Update test schedule subscription ID
    $dup_schedule->update($db, { stripe_subscription_id => 'sub_test_duplicate_webhook' });

    # Process the same invoice twice
    my $duplicate_invoice = {
        id => 'in_test_duplicate',
        subscription => 'sub_test_duplicate_webhook',
        payment_intent => 'pi_test_duplicate',
        status => 'paid'
    };

    # Get payment
    my @payments = $dup_schedule->scheduled_payments($db);
    my $payment = $payments[0];
    my $original_status = $payment->status;

    # First processing
    my $result1 = $payment_ops->handle_invoice_paid($db, $duplicate_invoice);
    ok $result1->{success}, 'First webhook processing succeeded';

    # Second processing (duplicate) - should handle gracefully
    my $result2 = $payment_ops->handle_invoice_paid($db, $duplicate_invoice);
    # May succeed or fail depending on implementation, but shouldn't crash
    ok defined($result2), 'Duplicate webhook processing handled without crashing';

    # Verify payment is correctly updated
    my $final_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $final_payment->status, 'completed', 'Payment status correctly updated';
};

subtest 'Error handling for missing subscription' => sub {
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;

    # Invoice for non-existent subscription
    my $missing_sub_invoice = {
        id => 'in_test_missing_sub',
        subscription => 'sub_nonexistent',
        payment_intent => 'pi_test_missing_sub',
        status => 'paid'
    };

    # Should handle gracefully and not crash
    my $result = $payment_ops->handle_invoice_paid($db, $missing_sub_invoice);
    # Should return undef or handle gracefully when subscription not found
    ok !$result || !$result->{success}, 'Missing subscription handled gracefully';
};

subtest 'Business logic integration completeness' => sub {
    # Test that all required business logic methods exist
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new;

    # Verify all webhook handling methods exist
    can_ok $payment_ops, 'handle_invoice_paid';
    can_ok $payment_ops, 'handle_invoice_payment_failed';
    can_ok $payment_ops, 'mark_payment_completed';
    can_ok $payment_ops, 'mark_payment_failed';

    # Verify payment schedule management methods exist
    can_ok $schedule_ops, 'create_for_enrollment';
    can_ok $schedule_ops, 'check_subscription_status';
    can_ok $schedule_ops, 'find_schedules_with_payment_issues';
};

done_testing;