#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Registry::DAO::Payment;
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
    name => 'Test Scheduled Payment Tenant',
    slug => 'test_scheduled_payment',
});
$dao->db->query('SELECT clone_schema(?)', 'test_scheduled_payment');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_scheduled_payment');
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
    installments_allowed => 1,
    installment_count => 3
});

# Create test parent user
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent'
});

# Create a mock enrollment
my $enrollment_id = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    status => 'pending',
    metadata => '{"test": "enrollment"}'
}, { returning => 'id' })->hash->{id};

# Create test parent with Stripe customer ID and mock Stripe client
my $parent_with_stripe = Registry::DAO::User->create($db, {
    email    => 'parent_stripe@example.com',
    username => 'testparentstripe',
    password => 'password123',
    name => 'Test Parent with Stripe',
    user_type => 'parent',
    stripe_customer_id => 'cus_test_mock_customer'
});

# Mock Stripe client for testing
use Test::MockObject;
my $mock_stripe = Test::MockObject->new;
$mock_stripe->set_always('create_installment_subscription', {
    id => 'sub_test_mock_subscription',
    status => 'active'
});

# Create payment schedule using Stripe-native approach
my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
my $schedule = $schedule_ops->create_for_enrollment($db, {
    enrollment_id => $enrollment_id,
    pricing_plan_id => $pricing_plan->id,
    customer_id => 'cus_test_mock_customer',
    payment_method_id => 'pm_test_mock_payment_method',
    total_amount => 300.00,
    installment_count => 3
});

subtest 'ScheduledPayment basic operations - Stripe tracking only' => sub {
    my @payments = $schedule->scheduled_payments($db);
    is scalar @payments, 3, 'Three scheduled payment trackers created';

    my $first_payment = $payments[0];
    isa_ok $first_payment, 'Registry::DAO::ScheduledPayment';
    is $first_payment->payment_schedule_id, $schedule->id, 'Payment tracker linked to schedule';
    is $first_payment->installment_number, 1, 'Correct installment number';
    is $first_payment->amount, '100.00', 'Correct payment amount';
    is $first_payment->status, 'pending', 'Payment tracker starts as pending';

    # Test payment_schedule relationship
    my $related_schedule = $first_payment->payment_schedule($db);
    is $related_schedule->id, $schedule->id, 'Can retrieve related schedule';
};

subtest 'Webhook-based status management' => sub {
    my @payments = $schedule->scheduled_payments($db);
    my $payment = $payments[0];

    # Test webhook-based completion (via PriceOps)
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;
    my $mock_invoice = {
        id => 'in_test_mock_invoice',
        subscription => 'sub_test_mock_subscription',
        payment_intent => 'pi_test_mock_payment_intent',
        status => 'paid'
    };

    my $result = $payment_ops->handle_invoice_paid($db, $mock_invoice);
    ok $result->{success}, 'Invoice paid webhook handled successfully';

    my $updated_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $updated_payment->status, 'completed', 'Payment status updated via webhook';
    ok $updated_payment->paid_at, 'Paid timestamp set by webhook';

    # Test webhook-based failure handling
    my $second_payment = $payments[1];
    my $failed_invoice = {
        id => 'in_test_mock_failed_invoice',
        subscription => 'sub_test_mock_subscription',
        payment_intent => 'pi_test_mock_failed_payment_intent',
        status => 'payment_failed'
    };

    my $failure_result = $payment_ops->handle_invoice_payment_failed($db, $failed_invoice);
    ok $failure_result->{success}, 'Invoice payment failed webhook handled successfully';

    my $updated_failed = Registry::DAO::ScheduledPayment->find($db, { id => $second_payment->id });
    is $updated_failed->status, 'failed', 'Payment status updated to failed via webhook';
    ok $updated_failed->failed_at, 'Failed timestamp set by webhook';
};

subtest 'Stripe Smart Retries - No manual retry logic needed' => sub {
    # With Stripe subscriptions, retries are handled automatically by Stripe Smart Retries
    # We just test that the webhook properly updates payment status

    my $retry_schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $retry_schedule = $retry_schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 150.00,
        installment_count => 3,
    });

    my @retry_payments = $retry_schedule->scheduled_payments($db);
    my $payment = $retry_payments[0];

    # Simulate Stripe Smart Retry: multiple webhook attempts
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;

    # First attempt fails (webhook)
    my $failed_invoice = {
        id => 'in_test_retry_failed',
        subscription => 'sub_test_mock_subscription',
        payment_intent => 'pi_test_retry_failed',
        status => 'payment_failed'
    };
    $payment_ops->handle_invoice_payment_failed($db, $failed_invoice);

    my $after_failure = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $after_failure->status, 'failed', 'Payment marked failed after first webhook';

    # Stripe retries and succeeds (second webhook)
    my $success_invoice = {
        id => 'in_test_retry_success',
        subscription => 'sub_test_mock_subscription',
        payment_intent => 'pi_test_retry_success',
        status => 'paid'
    };
    $payment_ops->handle_invoice_paid($db, $success_invoice);

    my $after_retry = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $after_retry->status, 'completed', 'Payment updated to completed after Stripe retry succeeds';
    ok $after_retry->paid_at, 'Paid timestamp set after successful retry';
};

subtest 'Stripe subscription status tracking - No due date logic needed' => sub {
    # With Stripe subscriptions, due dates are handled by Stripe
    # We only track payment status via webhooks

    my $test_schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $test_schedule = $test_schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 150.00,
        installment_count => 2,
    });

    my @payments = $test_schedule->scheduled_payments($db);
    my $payment = $payments[0];

    # Payment starts as pending - Stripe will attempt collection per subscription schedule
    is $payment->status, 'pending', 'Payment starts as pending - Stripe handles timing';

    # Test subscription-level past_due status (from Stripe)
    $mock_stripe->set_always('retrieve_subscription', {
        id => 'sub_test_mock_subscription',
        status => 'past_due'
    });

    my $subscription = $test_schedule_ops->check_subscription_status($db, $test_schedule);
    ok $subscription, 'Can check subscription status from Stripe';

    # Verify schedule status is updated based on Stripe subscription status
    my $updated_schedule = Registry::DAO::PaymentSchedule->find($db, { id => $test_schedule->id });
    is $updated_schedule->status, 'past_due', 'Schedule status synced with Stripe subscription';
};

subtest 'ScheduledPayment simplified class methods' => sub {
    # Test with webhook-updated statuses only
    my $test_schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $test_schedule = $test_schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 600.00,
        installment_count => 4,
    });

    my @test_payments = $test_schedule->scheduled_payments($db);

    # Set different statuses (via simulated webhooks)
    $test_payments[0]->update($db, { status => 'completed', paid_at => \'NOW()' });
    $test_payments[1]->update($db, { status => 'failed', failed_at => \'NOW()', failure_reason => 'Card declined' });
    # test_payments[2] and [3] remain 'pending'

    # Test find_failed (still needed for reporting)
    my @failed_payments = Registry::DAO::ScheduledPayment->find_failed($db);
    ok @failed_payments >= 1, 'Found failed payments';

    # Test find_by_schedule (still needed for relationships)
    my @schedule_payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $test_schedule->id);
    is scalar @schedule_payments, 4, 'Found all payment trackers for schedule';

    # Verify different statuses
    my @completed = grep { $_->status eq 'completed' } @schedule_payments;
    my @failed = grep { $_->status eq 'failed' } @schedule_payments;
    my @pending = grep { $_->status eq 'pending' } @schedule_payments;

    is scalar @completed, 1, 'One completed payment';
    is scalar @failed, 1, 'One failed payment';
    is scalar @pending, 2, 'Two pending payments';
};

subtest 'Stripe handles payment processing - webhook simulation' => sub {
    # With Stripe subscriptions, no manual processing is needed
    # Stripe handles collection attempts and sends webhooks

    my $proc_schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $proc_schedule = $proc_schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 200.00,
        installment_count => 2,
    });

    my @proc_payments = $proc_schedule->scheduled_payments($db);
    my $payment = $proc_payments[0];

    # Stripe processes payment and sends webhook
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;
    my $webhook_invoice = {
        id => 'in_test_processing',
        subscription => 'sub_test_mock_subscription',
        payment_intent => 'pi_test_processing',
        status => 'paid'
    };

    # Simulate webhook processing
    my $result = $payment_ops->handle_invoice_paid($db, $webhook_invoice);
    ok $result->{success}, 'Webhook processed successfully';

    my $updated = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $updated->status, 'completed', 'Payment completed via Stripe webhook';
    ok $updated->paid_at, 'Payment timestamp set by webhook';
};

subtest 'Database constraints for simplified schema' => sub {
    # Test database-level constraints for simplified schema
    eval {
        $db->insert('registry.scheduled_payments', {
            payment_schedule_id => $schedule->id,
            installment_number => 0,  # Should fail: must be > 0
            amount => 100.00,
        });
    };
    ok $@, 'Database rejects installment_number <= 0';

    eval {
        $db->insert('registry.scheduled_payments', {
            payment_schedule_id => $schedule->id,
            installment_number => 1,
            amount => -50.00,  # Should fail: must be positive
        });
    };
    ok $@, 'Database rejects negative amount';

    # Test new status constraints work
    my $test_payment_id = $db->insert('registry.scheduled_payments', {
        payment_schedule_id => $schedule->id,
        installment_number => 5,
        amount => 50.00,
        status => 'completed'
    }, { returning => 'id' })->hash->{id};

    ok $test_payment_id, 'Database accepts completed status';
};

done_testing;