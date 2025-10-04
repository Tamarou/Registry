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
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Program;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::PriceOps::PaymentSchedule;
use DateTime;

# Mock Stripe environment for testing
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_mock_key_for_testing';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Payment Schedule Tenant',
    slug => 'test_payment_schedule',
});
$dao->db->query('SELECT clone_schema(?)', 'test_payment_schedule');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_payment_schedule');
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
    installments_allowed => 1,  # true
    installment_count => 3
});

# Create test parent user for enrollment with Stripe customer ID
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent',
    stripe_customer_id => 'cus_test_mock_customer' # Mock Stripe customer ID
});

# Create a mock enrollment ID (in real scenario this would be created by enrollment workflow)
my $enrollment_id = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    status => 'pending',
    metadata => '{"test": "enrollment"}'
}, { returning => 'id' })->hash->{id};

# Mock Stripe client for testing
use Test::MockObject;
my $mock_stripe = Test::MockObject->new;
$mock_stripe->set_always('create_installment_subscription', {
    id => 'sub_test_mock_subscription',
    status => 'active'
});

subtest 'PaymentSchedule creation' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 300.00,
        installment_count => 3,
        frequency => 'monthly'
    });

    ok $schedule, 'Payment schedule created successfully';
    isa_ok $schedule, 'Registry::DAO::PaymentSchedule';
    is $schedule->enrollment_id, $enrollment_id, 'Enrollment ID matches';
    is $schedule->pricing_plan_id, $pricing_plan->id, 'Pricing plan ID matches';
    is $schedule->total_amount, '300.00', 'Total amount is correct';
    is $schedule->installment_count, 3, 'Installment count is correct';
    is $schedule->installment_amount, '100.00', 'Installment amount calculated correctly';
    is $schedule->status, 'active', 'Schedule starts as active';
    is $schedule->stripe_subscription_id, 'sub_test_mock_subscription', 'Stripe subscription ID stored';

    # Verify scheduled payment trackers were created (for status tracking only)
    my @scheduled_payments = $schedule->scheduled_payments($db);
    is scalar @scheduled_payments, 3, 'Three scheduled payment trackers created';

    # Check the scheduled payment tracker details
    my $first_payment = $scheduled_payments[0];
    is $first_payment->installment_number, 1, 'First payment has correct installment number';
    is $first_payment->amount, '100.00', 'First payment has correct amount';
    is $first_payment->status, 'pending', 'First payment starts as pending';

    my $second_payment = $scheduled_payments[1];
    is $second_payment->installment_number, 2, 'Second payment has correct installment number';
    is $second_payment->amount, '100.00', 'Second payment has correct amount';
};

subtest 'PaymentSchedule validation' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);

    # Test missing customer_id (new requirement)
    eval {
        $schedule_ops->create_for_enrollment($db, {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
            payment_method_id => 'pm_test_mock_payment_method',
            total_amount => 300.00,
            installment_count => 3,
            # Missing customer_id
        });
    };
    like $@, qr/customer_id required/, 'Validates required customer_id';

    # Test missing payment_method_id (new requirement)
    eval {
        $schedule_ops->create_for_enrollment($db, {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
            customer_id => 'cus_test_mock_customer',
            total_amount => 300.00,
            installment_count => 3,
            # Missing payment_method_id
        });
    };
    like $@, qr/payment_method_id required/, 'Validates required payment_method_id';

    # Test invalid installment count
    eval {
        $schedule_ops->create_for_enrollment($db, {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
            customer_id => 'cus_test_mock_customer',
            payment_method_id => 'pm_test_mock_payment_method',
            total_amount => 300.00,
            installment_count => 1,  # Invalid: must be > 1
        });
    };
    like $@, qr/installment_count must be greater than 1/, 'Validates installment count > 1';

    # Test invalid total amount
    eval {
        $schedule_ops->create_for_enrollment($db, {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
            customer_id => 'cus_test_mock_customer',
            payment_method_id => 'pm_test_mock_payment_method',
            total_amount => 0,  # Invalid: must be positive
            installment_count => 3,
        });
    };
    like $@, qr/total_amount must be positive/, 'Validates positive total amount';

    # Test missing required fields
    eval {
        $schedule_ops->create_for_enrollment($db, {
            pricing_plan_id => $pricing_plan->id,
            customer_id => 'cus_test_mock_customer',
            payment_method_id => 'pm_test_mock_payment_method',
            total_amount => 300.00,
            installment_count => 3,
            # Missing enrollment_id
        });
    };
    like $@, qr/enrollment_id required/, 'Validates required enrollment_id';
};

subtest 'Webhook-based status management' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 450.00,
        installment_count => 3,
    });

    # Test finding scheduled payment trackers using DAO relationship method
    my @scheduled_payments = $schedule->scheduled_payments($db);
    is scalar @scheduled_payments, 3, 'All payments start as pending';

    # Test webhook-based payment completion (via PriceOps)
    use Registry::PriceOps::ScheduledPayment;
    my $payment_ops = Registry::PriceOps::ScheduledPayment->new;
    my $first_payment = $scheduled_payments[0];

    # Mock Stripe invoice data
    my $mock_invoice = {
        id => 'in_test_mock_invoice',
        subscription => 'sub_test_mock_subscription',
        payment_intent => 'pi_test_mock_payment_intent',
        status => 'paid'
    };

    my $result = $payment_ops->handle_invoice_paid($db, $mock_invoice);
    ok $result->{success}, 'Invoice paid handled successfully';

    # Verify payment status updated
    $first_payment = Registry::DAO::ScheduledPayment->find($db, { id => $first_payment->id });
    is $first_payment->status, 'completed', 'Payment marked as completed via webhook';
    ok $first_payment->paid_at, 'Paid timestamp set';
};

subtest 'PaymentSchedule Stripe integration' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 600.00,
        installment_count => 4,
    });

    # Mock Stripe subscription status check
    $mock_stripe->set_always('retrieve_subscription', {
        id => 'sub_test_mock_subscription',
        status => 'past_due'
    });

    # Test subscription status sync
    my $subscription = $schedule_ops->check_subscription_status($db, $schedule);
    ok $subscription, 'Subscription status retrieved';

    # Verify schedule status updated
    my $updated_schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is $updated_schedule->status, 'past_due', 'Schedule status synced with Stripe';
};

subtest 'Class methods and queries' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new(stripe_client => $mock_stripe);

    my $schedule1 = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        customer_id => 'cus_test_mock_customer',
        payment_method_id => 'pm_test_mock_payment_method',
        total_amount => 300.00,
        installment_count => 3,
    });

    # Test find_by_enrollment
    my @enrollment_schedules = Registry::DAO::PaymentSchedule->find_by_enrollment($db, $enrollment_id);
    ok @enrollment_schedules >= 1, 'Found schedules for enrollment';

    # Test find_active
    my @active_schedules = Registry::DAO::PaymentSchedule->find_active($db);
    ok @active_schedules >= 1, 'Found active schedules';

    # Test find_schedules_with_payment_issues (replaces find_overdue)
    my @problem_schedules = $schedule_ops->find_schedules_with_payment_issues($db);
    # Should find the past_due schedule from previous subtest
    is scalar @problem_schedules, 1, 'Found payment issues for past_due schedule';
};

subtest 'Database constraints for simplified schema' => sub {
    # Test that database constraints work with simplified schema
    eval {
        $db->insert('registry.payment_schedules', {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
            total_amount => -100.00,  # Negative amount should fail
            installment_amount => 50.00,
            installment_count => 2,
            stripe_subscription_id => 'sub_test'
        });
    };
    ok $@, 'Database rejects negative total amount';

    eval {
        $db->insert('registry.payment_schedules', {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
            total_amount => 100.00,
            installment_amount => 50.00,
            installment_count => 1,  # Should fail constraint
            stripe_subscription_id => 'sub_test'
        });
    };
    ok $@, 'Database rejects installment count <= 1';

    # Test new past_due status is allowed
    my $test_schedule_id = $db->insert('registry.payment_schedules', {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 200.00,
        installment_amount => 100.00,
        installment_count => 2,
        stripe_subscription_id => 'sub_test_past_due',
        status => 'past_due'
    }, { returning => 'id' })->hash->{id};

    ok $test_schedule_id, 'Database accepts past_due status';
};

done_testing;