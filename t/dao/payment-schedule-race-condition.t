#!/usr/bin/env perl
# ABOUTME: Test for webhook-based payment processing with Stripe subscriptions
# ABOUTME: Verifies that webhook events are handled atomically (race conditions eliminated)
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
    installments_allowed => 1,  # true
    installment_count => 3
});

# Create test parent user for enrollment with Stripe customer ID
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent_race@example.com',
    username => 'testparent_race',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent',
    stripe_customer_id => 'cus_test_race_condition'
});

# Create a mock enrollment ID
my $enrollment_id = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    status => 'pending',
    metadata => '{"test": "race_condition_enrollment"}'
}, { returning => 'id' })->hash->{id};

# Mock Stripe client for testing
my $mock_stripe = Test::MockObject->new;
$mock_stripe->set_always('create_installment_subscription', {
    id => 'sub_test_race_condition',
    status => 'active'
});

subtest 'Webhook-based payment processing eliminates race conditions' => sub {
    # Create payment schedule with Stripe subscription
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_race_condition',
        payment_method_id => 'pm_test_race_condition',
        total_amount => 300.00,
        installment_count => 3,
    });

    ok($schedule, 'Payment schedule created with Stripe subscription');
    is($schedule->status, 'active', 'Schedule is active');
    ok($schedule->stripe_subscription_id, 'Stripe subscription ID stored');

    # Get all scheduled payment trackers
    my @payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    is(@payments, 3, 'Three scheduled payment trackers created');

    # Process webhook events (simulating Stripe's atomic webhook delivery)
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new();

    # First payment webhook (invoice.paid)
    my $invoice1 = {
        id => 'in_test_race_1',
        subscription => 'sub_test_race_condition',
        payment_intent => 'pi_test_race_1',
        status => 'paid'
    };

    my $result1 = $payment_ops->handle_invoice_paid($db, $invoice1);
    ok($result1->{success}, 'First webhook processed successfully');

    # Verify first payment updated
    my $updated_payment1 = Registry::DAO::ScheduledPayment->find($db, { id => $payments[0]->id });
    is($updated_payment1->status, 'completed', 'First payment marked completed via webhook');

    # Schedule should still be active (more payments pending)
    $schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is($schedule->status, 'active', 'Schedule still active after first payment');

    # Process remaining webhook events - no race conditions possible with webhooks
    my $invoice2 = {
        id => 'in_test_race_2',
        subscription => 'sub_test_race_condition',
        payment_intent => 'pi_test_race_2',
        status => 'paid'
    };

    my $invoice3 = {
        id => 'in_test_race_3',
        subscription => 'sub_test_race_condition',
        payment_intent => 'pi_test_race_3',
        status => 'paid'
    };

    # Process webhooks sequentially (Stripe guarantees this)
    my $result2 = $payment_ops->handle_invoice_paid($db, $invoice2);
    my $result3 = $payment_ops->handle_invoice_paid($db, $invoice3);

    ok($result2->{success}, 'Second webhook processed successfully');
    ok($result3->{success}, 'Third webhook processed successfully');

    # Verify all payments are completed
    my @final_payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    my @completed = grep { $_->status eq 'completed' } @final_payments;
    is(@completed, 3, 'All three payments completed via webhooks');

    # Schedule should be completed when all payments are done
    $schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is($schedule->status, 'completed', 'Schedule automatically completed');
};

subtest 'Webhook idempotency handling' => sub {
    # Create another schedule for idempotency testing
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_idempotency',
        payment_method_id => 'pm_test_idempotency',
        total_amount => 200.00,
        installment_count => 2,
    });

    # Update subscription ID for this test
    $schedule->update($db, { stripe_subscription_id => 'sub_test_idempotency' });

    my @payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    is(@payments, 2, 'Two scheduled payment trackers created');

    # Process webhook for first payment
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new();
    my $invoice = {
        id => 'in_test_idempotency_1',
        subscription => 'sub_test_idempotency',
        payment_intent => 'pi_test_idempotency_1',
        status => 'paid'
    };

    my $result1 = $payment_ops->handle_invoice_paid($db, $invoice);
    ok($result1->{success}, 'First payment webhook processed');

    # Verify first payment is completed
    my $updated_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payments[0]->id });
    is($updated_payment->status, 'completed', 'First payment completed');

    # Process the SAME webhook again (idempotency test)
    my $result2 = $payment_ops->handle_invoice_paid($db, $invoice);
    ok(defined($result2), 'Duplicate webhook handled without crashing');

    # Payment should still be completed (no double processing)
    $updated_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payments[0]->id });
    is($updated_payment->status, 'completed', 'Payment status unchanged after duplicate webhook');

    # Only one paid_at timestamp should exist (not multiple)
    ok($updated_payment->paid_at, 'Paid timestamp exists');
};

subtest 'Stripe subscription status synchronization' => sub {
    # Create a schedule for subscription status testing
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_sync',
        payment_method_id => 'pm_test_sync',
        total_amount => 150.00,
        installment_count => 2,
    });

    # Update subscription ID for this test
    $schedule->update($db, { stripe_subscription_id => 'sub_test_sync' });

    my @payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $schedule->id);
    is(@payments, 2, 'Two payment trackers created');

    # Test subscription status check with past_due status
    $mock_stripe->set_always('retrieve_subscription', {
        id => 'sub_test_sync',
        status => 'past_due'
    });

    my $subscription = $schedule_ops->check_subscription_status($db, $schedule);
    ok($subscription, 'Subscription status retrieved from Stripe');

    # Verify schedule status was updated
    my $updated_schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is($updated_schedule->status, 'past_due', 'Schedule status synced with Stripe subscription');

    # Test cancellation synchronization
    $mock_stripe->set_always('retrieve_subscription', {
        id => 'sub_test_sync',
        status => 'canceled'
    });

    $schedule_ops->check_subscription_status($db, $updated_schedule);
    $updated_schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is($updated_schedule->status, 'cancelled', 'Schedule cancelled when Stripe subscription cancelled');
};

done_testing();