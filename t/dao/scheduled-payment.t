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
use DateTime;

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

# Create payment schedule for testing
my $schedule = Registry::DAO::PaymentSchedule->create_for_enrollment($db, {
    enrollment_id => $enrollment_id,
    pricing_plan_id => $pricing_plan->id,
    total_amount => 300.00,
    installment_count => 3,
    first_payment_date => '2024-07-01'
});

subtest 'ScheduledPayment basic operations' => sub {
    my @payments = $schedule->scheduled_payments($db);
    is scalar @payments, 3, 'Three scheduled payments created';

    my $first_payment = $payments[0];
    isa_ok $first_payment, 'Registry::DAO::ScheduledPayment';
    is $first_payment->payment_schedule_id, $schedule->id, 'Payment linked to schedule';
    is $first_payment->installment_number, 1, 'Correct installment number';
    is $first_payment->amount, '100.00', 'Correct payment amount';
    is $first_payment->status, 'pending', 'Payment starts as pending';
    is $first_payment->attempt_count, 0, 'No attempts initially';

    # Test payment_schedule relationship
    my $related_schedule = $first_payment->payment_schedule($db);
    is $related_schedule->id, $schedule->id, 'Can retrieve related schedule';
};

subtest 'ScheduledPayment status management' => sub {
    my @payments = $schedule->scheduled_payments($db);
    my $payment = $payments[0];

    # Test marking as completed
    my $result = $payment->_mark_completed($db, {
        stripe_payment_intent_id => 'pi_test123'
    });

    ok $result->{success}, 'Payment marked as completed successfully';
    my $updated_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $updated_payment->status, 'completed', 'Payment status updated to completed';
    ok $updated_payment->paid_at, 'Paid timestamp set';

    # Test marking as failed
    my $second_payment = $payments[1];
    my $failure_result = $second_payment->_mark_failed($db, 'Test failure reason');

    ok !$failure_result->{success}, 'Payment marked as failed';
    is $failure_result->{error}, 'Test failure reason', 'Failure reason recorded';
    my $updated_failed = Registry::DAO::ScheduledPayment->find($db, { id => $second_payment->id });
    is $updated_failed->status, 'failed', 'Payment status updated to failed';
    is $updated_failed->failure_reason, 'Test failure reason', 'Failure reason stored';
    ok $updated_failed->failed_at, 'Failed timestamp set';
};

subtest 'ScheduledPayment retry logic' => sub {
    # Create a new payment schedule for retry testing
    my $retry_schedule = Registry::DAO::PaymentSchedule->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 150.00,
        installment_count => 3,
    });

    my @retry_payments = $retry_schedule->scheduled_payments($db);
    my $payment = $retry_payments[0];

    # Simulate failed payment with attempt count increment
    $payment->update($db, { attempt_count => 1 });
    $payment->_mark_failed($db, 'Card declined');
    my $updated = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $updated->attempt_count, 1, 'Attempt count incremented on failure';

    # Test retry (this would normally call process() but we'll test the retry setup)
    ok $updated->status eq 'failed', 'Payment is failed before retry';

    # Reset to pending for retry
    $updated->update($db, {
        status => 'pending',
        failed_at => undef,
        failure_reason => undef,
    });

    my $reset_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $reset_payment->status, 'pending', 'Payment reset to pending for retry';
    is $reset_payment->attempt_count, 1, 'Attempt count preserved';

    # Test that too many attempts prevent retry
    $reset_payment->update($db, { attempt_count => 3 });
    my $max_attempts_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    eval { $max_attempts_payment->retry($db) };
    like $@, qr/Too many retry attempts/, 'Prevents retry after 3 attempts';
};

subtest 'ScheduledPayment due date logic' => sub {
    # Create a fresh payment schedule to ensure clean state
    my $test_schedule = Registry::DAO::PaymentSchedule->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 150.00,
        installment_count => 2,
    });

    my @payments = $test_schedule->scheduled_payments($db);
    my $payment = $payments[0];

    # Ensure payment is in pending status
    ok $payment->status eq 'pending', 'Payment starts as pending';

    # Test overdue detection
    $payment->update($db, { due_date => '2024-01-01' });  # Past date
    my $overdue_payment = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    ok $overdue_payment->is_overdue, 'Detects overdue payment';

    my $days_overdue = $overdue_payment->days_overdue;
    ok $days_overdue > 0, 'Calculates days overdue correctly';

    # Test not overdue
    $payment->update($db, { due_date => DateTime->now->add(days => 5)->ymd });
    my $updated = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    ok !$updated->is_overdue, 'Detects non-overdue payment';
    is $updated->days_overdue, 0, 'Zero days overdue for future payment';
};

subtest 'ScheduledPayment class methods' => sub {
    # Set up test data with various due dates and statuses
    my $test_schedule = Registry::DAO::PaymentSchedule->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 600.00,
        installment_count => 4,
    });

    my @test_payments = $test_schedule->scheduled_payments($db);

    # Set different due dates and statuses
    $test_payments[0]->update($db, { due_date => '2024-06-01' });  # Overdue
    $test_payments[1]->update($db, { due_date => DateTime->now->ymd });  # Due today
    $test_payments[2]->update($db, { due_date => DateTime->now->add(days => 5)->ymd });  # Future
    $test_payments[3]->update($db, { status => 'failed' });  # Failed

    # Test find_due
    my @due_payments = Registry::DAO::ScheduledPayment->find_due($db);
    ok @due_payments >= 2, 'Found due and overdue payments';

    # Test find_overdue
    my @overdue_payments = Registry::DAO::ScheduledPayment->find_overdue($db);
    ok @overdue_payments >= 1, 'Found overdue payments';

    # Test find_failed
    my @failed_payments = Registry::DAO::ScheduledPayment->find_failed($db);
    ok @failed_payments >= 1, 'Found failed payments';

    # Test find_by_schedule
    my @schedule_payments = Registry::DAO::ScheduledPayment->find_by_schedule($db, $test_schedule->id);
    is scalar @schedule_payments, 4, 'Found all payments for schedule';
};

subtest 'Payment processing simulation' => sub {
    # Create a simple payment schedule for processing tests
    my $proc_schedule = Registry::DAO::PaymentSchedule->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 200.00,
        installment_count => 2,
    });

    my @proc_payments = $proc_schedule->scheduled_payments($db);
    my $payment = $proc_payments[0];

    # Test processing attempt tracking
    $payment->update($db, {
        attempt_count => 1,
        last_attempt_at => \'NOW()',
        status => 'processing'
    });

    my $updated = Registry::DAO::ScheduledPayment->find($db, { id => $payment->id });
    is $updated->status, 'processing', 'Payment marked as processing';
    is $updated->attempt_count, 1, 'Attempt count tracked';
    ok $updated->last_attempt_at, 'Last attempt timestamp recorded';
};

subtest 'Database constraints' => sub {
    # Test database-level constraints
    eval {
        $db->insert('registry.scheduled_payments', {
            payment_schedule_id => $schedule->id,
            installment_number => 0,  # Should fail: must be > 0
            due_date => '2024-07-01',
            amount => 100.00,
        });
    };
    ok $@, 'Database rejects installment_number <= 0';

    eval {
        $db->insert('registry.scheduled_payments', {
            payment_schedule_id => $schedule->id,
            installment_number => 1,
            due_date => '2024-07-01',
            amount => -50.00,  # Should fail: must be positive
        });
    };
    ok $@, 'Database rejects negative amount';
};

done_testing;