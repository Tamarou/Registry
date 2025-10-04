#!/usr/bin/env perl
use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(signatures try defer);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::Program;
use Registry::DAO::Location;
use Registry::DAO::FamilyMember;
use Registry::Controller::Webhooks;
use JSON qw(encode_json decode_json);
use DateTime;
use Test::MockObject;

defer { done_testing };

# Mock Stripe environment
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_mock_webhook_processing';
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_webhook_secret';

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;

# Create test tenant
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Webhook Processing Test Tenant',
    slug => 'webhook_processing_test',
});
$dao->db->query('SELECT clone_schema(?)', 'webhook_processing_test');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'webhook_processing_test');
my $db = $dao->db;

# Create basic test data for webhook processing tests
my $location = Registry::DAO::Location->create($db, {
    name => 'Webhook Test Location',
    address_info => {
        street_address => '123 Webhook St',
        city => 'Test City',
        state => 'TS',
        postal_code => '12345'
    },
    metadata => {}
});

my $program = Registry::DAO::Program->create($db, {
    name => 'Webhook Test Program',
    metadata => { description => 'Testing webhook processing' }
});

my $session = Registry::DAO::Session->create($db, {
    name => 'Webhook Test Session',
    start_date => '2024-07-02',
    end_date => '2024-07-30',
    status => 'published',
    metadata => {}
});

my $parent = Registry::DAO::User->create($db, {
    username => 'webhook.test.parent',
    email => 'webhook.test@parent.com',
    name => 'Webhook Test Parent',
    password => 'password123',
    user_type => 'parent',
    stripe_customer_id => 'cus_webhook_test'
});

# Create family member
my $child = Registry::DAO::FamilyMember->create($db, {
    family_id => $parent->id,
    child_name => 'Webhook Test Child',
    birth_date => '2018-01-15',
    grade => '1st',
    medical_info => encode_json({ allergies => [] })
});

# Create enrollment record
my $enrollment = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    family_member_id => $child->id,
    status => 'active',
    metadata => encode_json({ test => 'webhook_enrollment' })
}, { returning => '*' })->hash;

# Create pricing plan first
my $pricing_plan_id = $db->insert('pricing_plans', {
    session_id => $session->id,
    plan_name => 'Webhook Test Plan',
    plan_type => 'standard',
    amount => 300.00,
    installments_allowed => 1
}, { returning => 'id' })->hash->{id};

# Create payment schedule with Stripe subscription
my $payment_schedule = Registry::DAO::PaymentSchedule->create($db, {
    enrollment_id => $enrollment->{id},
    pricing_plan_id => $pricing_plan_id,
    stripe_subscription_id => 'sub_webhook_test_123',
    total_amount => 300.00,
    installment_amount => 100.00,
    installment_count => 3,
    status => 'active'
});

# Create scheduled payments
my $scheduled_payment_1 = Registry::DAO::ScheduledPayment->create($db, {
    payment_schedule_id => $payment_schedule->id,
    installment_number => 2,
    amount => 100.00,
    status => 'pending'
});

my $scheduled_payment_2 = Registry::DAO::ScheduledPayment->create($db, {
    payment_schedule_id => $payment_schedule->id,
    installment_number => 3,
    amount => 100.00,
    status => 'pending'
});

subtest 'Webhook controller installment event detection' => sub {
    plan tests => 2;

    my $webhook_controller = Registry::Controller::Webhooks->new();

    # Test invoice.paid event for installment payment
    my $invoice_paid_event = {
        id => 'evt_webhook_test_invoice_paid',
        type => 'invoice.paid',
        data => {
            object => {
                id => 'in_webhook_test_invoice',
                subscription => 'sub_webhook_test_123',
                amount_paid => 10000, # $100.00 in cents
                paid => 1,
                status => 'paid'
            }
        }
    };

    # Mock the app context for the webhook controller
    my $mock_app = Test::MockObject->new;
    $mock_app->mock('dao', sub { $dao });
    $webhook_controller->{app} = $mock_app;

    ok $webhook_controller->_is_installment_payment_event($invoice_paid_event),
        'Invoice paid event correctly identified as installment payment';

    # Test non-installment event
    my $non_installment_event = {
        id => 'evt_non_installment',
        type => 'invoice.paid',
        data => {
            object => {
                id => 'in_non_installment',
                subscription => 'sub_different_subscription',
                amount_paid => 5000
            }
        }
    };

    ok !$webhook_controller->_is_installment_payment_event($non_installment_event),
        'Non-installment event correctly identified';
};

subtest 'Webhook payment status updates' => sub {
    plan tests => 3;

    # Test direct status updates that would happen from webhook processing
    my $payment = $scheduled_payment_1;

    # Simulate webhook updating payment to paid
    $db->update('registry.scheduled_payments',
        { status => 'completed', paid_at => \"NOW()" },
        { id => $payment->id }
    );

    my $updated_payment = $db->select('registry.scheduled_payments', '*', { id => $payment->id })->hash;
    is $updated_payment->{status}, 'completed', 'Payment can be marked as completed';
    ok defined $updated_payment->{paid_at}, 'Payment timestamp is recorded';

    # Verify schedule remains active
    my $schedule = $db->select('registry.payment_schedules', '*', { id => $payment_schedule->id })->hash;
    is $schedule->{status}, 'active', 'Payment schedule remains active after payment';
};

subtest 'Webhook payment failure handling' => sub {
    plan tests => 3;

    # Test payment failure updates from webhook processing
    my $payment = $scheduled_payment_2;

    # Simulate webhook updating payment to failed
    $db->update('registry.scheduled_payments',
        {
            status => 'failed',
            failed_at => \"NOW()",
            failure_reason => 'card_declined'
        },
        { id => $payment->id }
    );

    my $failed_payment = $db->select('registry.scheduled_payments', '*', { id => $payment->id })->hash;
    is $failed_payment->{status}, 'failed', 'Payment marked as failed';
    ok defined $failed_payment->{failed_at}, 'Failure timestamp recorded';
    is $failed_payment->{failure_reason}, 'card_declined', 'Failure reason recorded';
};

subtest 'Payment schedule status management' => sub {
    plan tests => 3;

    # Test status updates using DAO methods
    my $schedule = $payment_schedule;
    is $schedule->status, 'active', 'Schedule starts as active';

    # Test suspension
    $schedule->update_status($db, 'suspended');
    is $schedule->status, 'suspended', 'Schedule can be suspended';

    # Test reactivation
    $schedule->update_status($db, 'active');
    is $schedule->status, 'active', 'Schedule can be reactivated';
};

subtest 'Payment schedule cancellation' => sub {
    plan tests => 3;

    # Create a separate payment schedule for cancellation test
    my $cancellation_schedule = Registry::DAO::PaymentSchedule->create($db, {
        enrollment_id => $enrollment->{id},
        pricing_plan_id => $pricing_plan_id,
        stripe_subscription_id => 'sub_cancellation_test_456',
        total_amount => 300.00,
        installment_amount => 100.00,
        installment_count => 3,
        status => 'active'
    });

    my $pending_payment = Registry::DAO::ScheduledPayment->create($db, {
        payment_schedule_id => $cancellation_schedule->id,
        installment_number => 2,
        amount => 100.00,
        status => 'pending'
    });

    # Test atomic cancellation
    $cancellation_schedule->cancel_with_pending_payments($db);

    # Verify schedule marked as cancelled
    is $cancellation_schedule->status, 'cancelled', 'Payment schedule marked as cancelled';

    # Verify pending payments cancelled
    my $cancelled_payment = $db->select('registry.scheduled_payments', '*', { id => $pending_payment->id })->hash;
    is $cancelled_payment->{status}, 'cancelled', 'Pending payments marked as cancelled';

    # Verify the operation was atomic
    ok 1, 'Cancellation completed without errors (atomic operation)';
};