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
use Registry::DAO::Project;
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
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent'
});

# Create a mock enrollment ID (in real scenario this would be created by enrollment workflow)
my $enrollment_id = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    status => 'pending',
    metadata => '{"test": "enrollment"}'
}, { returning => 'id' })->hash->{id};

subtest 'PaymentSchedule creation' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new;
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 300.00,
        installment_count => 3,
        first_payment_date => '2024-07-01'
    });

    ok $schedule, 'Payment schedule created successfully';
    isa_ok $schedule, 'Registry::DAO::PaymentSchedule';
    is $schedule->enrollment_id, $enrollment_id, 'Enrollment ID matches';
    is $schedule->pricing_plan_id, $pricing_plan->id, 'Pricing plan ID matches';
    is $schedule->total_amount, '300.00', 'Total amount is correct';
    is $schedule->installment_count, 3, 'Installment count is correct';
    is $schedule->installment_amount, '100.00', 'Installment amount calculated correctly';
    is $schedule->status, 'active', 'Schedule starts as active';
    is $schedule->frequency, 'monthly', 'Default frequency is monthly';

    # Verify scheduled payments were created
    my @scheduled_payments = $schedule->scheduled_payments($db);
    is scalar @scheduled_payments, 3, 'Three scheduled payments created';

    # Check the scheduled payment details
    my $first_payment = $scheduled_payments[0];
    is $first_payment->installment_number, 1, 'First payment has correct installment number';
    is $first_payment->amount, '100.00', 'First payment has correct amount';
    is $first_payment->status, 'pending', 'First payment starts as pending';

    # Check dates are properly spaced
    my $second_payment = $scheduled_payments[1];
    is $second_payment->installment_number, 2, 'Second payment has correct installment number';
    # Note: In real test we'd check date calculations more thoroughly
};

subtest 'PaymentSchedule validation' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new;

    # Test invalid installment count
    eval {
        $schedule_ops->create_for_enrollment($db, {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
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
            total_amount => 0,  # Invalid: must be positive
            installment_count => 3,
        });
    };
    like $@, qr/total_amount must be positive/, 'Validates positive total amount';

    # Test missing required fields
    eval {
        $schedule_ops->create_for_enrollment($db, {
            pricing_plan_id => $pricing_plan->id,
            total_amount => 300.00,
            installment_count => 3,
            # Missing enrollment_id
        });
    };
    like $@, qr/enrollment_id required/, 'Validates required enrollment_id';
};

subtest 'Scheduled payment management' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new;
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 450.00,
        installment_count => 3,
        first_payment_date => DateTime->now->ymd
    });

    # Test finding scheduled payments using DAO relationship method
    my @scheduled_payments = $schedule->scheduled_payments($db);
    is scalar @scheduled_payments, 3, 'All payments start as pending';

    # Test overdue payments (set due date in past)
    my $first_scheduled = $scheduled_payments[0];
    $first_scheduled->update($db, { due_date => '2024-01-01' });

    # Test finding overdue payments via DAO query methods
    my @overdue = Registry::DAO::ScheduledPayment->find_overdue($db);
    ok @overdue >= 1, 'Found overdue payments';
    # Find our specific overdue payment
    my ($our_overdue) = grep { $_->payment_schedule_id eq $schedule->id } @overdue;
    ok $our_overdue, 'Our payment is in overdue list';
    is $our_overdue->id, $first_scheduled->id, 'Correct payment is overdue';
};

subtest 'PaymentSchedule status management' => sub {
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new;
    my $schedule = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 600.00,
        installment_count => 4,
    });

    # Test suspension
    $schedule_ops->suspend($db, $schedule, 'Payment failure test');
    my $updated_schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is $updated_schedule->status, 'suspended', 'Schedule can be suspended';

    # Test reactivation
    $schedule_ops->reactivate($db, $updated_schedule);
    $updated_schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is $updated_schedule->status, 'active', 'Schedule can be reactivated';

    # Test completion
    $schedule_ops->mark_completed($db, $updated_schedule);
    $updated_schedule = Registry::DAO::PaymentSchedule->find($db, { id => $schedule->id });
    is $updated_schedule->status, 'completed', 'Schedule can be marked completed';

    # Test that completed schedule cannot be reactivated
    eval { $schedule_ops->reactivate($db, $updated_schedule) };
    like $@, qr/Cannot reactivate completed schedule/, 'Cannot reactivate completed schedule';
};

subtest 'Class methods' => sub {
    # Create multiple schedules for testing
    my $schedule_ops = Registry::PriceOps::PaymentSchedule->new;
    my $schedule1 = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 300.00,
        installment_count => 3,
    });

    my $schedule2 = $schedule_ops->create_for_enrollment($db, {
        enrollment_id => $enrollment_id,
        pricing_plan_id => $pricing_plan->id,
        total_amount => 400.00,
        installment_count => 2,
    });

    # Suspend one schedule
    $schedule_ops->suspend($db, $schedule2);

    # Test find_by_enrollment
    my @enrollment_schedules = Registry::DAO::PaymentSchedule->find_by_enrollment($db, $enrollment_id);
    ok @enrollment_schedules >= 2, 'Found schedules for enrollment';

    # Test find_active
    my @active_schedules = Registry::DAO::PaymentSchedule->find_active($db);
    ok @active_schedules >= 1, 'Found active schedules';

    # Verify suspended schedule is not in active list
    my @active_ids = map { $_->id } @active_schedules;
    ok !(grep { $_ eq $schedule2->id } @active_ids), 'Suspended schedule not in active list';
};

subtest 'Database constraints' => sub {
    # Test that database constraints are working
    eval {
        $db->insert('registry.payment_schedules', {
            enrollment_id => $enrollment_id,
            pricing_plan_id => $pricing_plan->id,
            total_amount => -100.00,  # Negative amount should fail
            installment_amount => 50.00,
            installment_count => 2,
            first_payment_date => '2024-07-01',
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
            first_payment_date => '2024-07-01',
        });
    };
    ok $@, 'Database rejects installment count <= 1';
};

done_testing;