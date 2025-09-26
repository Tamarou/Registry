#!/usr/bin/env perl
use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More;
defer { done_testing };

# Test installment payment functionality end-to-end
use Registry::DAO::PaymentSchedule;
use Registry::DAO::ScheduledPayment;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::User;
use Registry::DAO::FamilyMember;
use JSON qw(encode_json);

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

# Create test data outside subtests to reuse
my $location = Registry::DAO::Location->create($db, {
    name => 'E2E Test Location',
    address_info => {
        street_address => '123 E2E St',
        city => 'Test City',
        state => 'TS',
        postal_code => '12345'
    },
    metadata => {}
});

my $project = Registry::DAO::Project->create($db, {
    name => 'E2E Test Project',
    metadata => { description => 'End-to-end testing project' }
});

my $parent = Registry::DAO::User->create($db, {
    username => 'e2e.parent',
    email => 'e2e.parent@test.com',
    name => 'E2E Test Parent',
    password => 'password123',
    user_type => 'parent'
});

my $session = Registry::DAO::Session->create($db, {
    name => 'E2E Test Session',
    start_date => '2024-07-02',
    end_date => '2024-07-09',
    status => 'published',
    metadata => {}
});

my $child = Registry::DAO::FamilyMember->create($db, {
    family_id => $parent->id,
    child_name => 'E2E Test Child',
    birth_date => '2018-01-15',
    grade => '1st',
    medical_info => encode_json({ allergies => [] })
});

my $enrollment_id = $db->insert('enrollments', {
    session_id => $session->id,
    student_id => $parent->id,
    family_member_id => $child->id,
    status => 'active',
    metadata => '{"test": "e2e_enrollment"}'
}, { returning => 'id' })->hash->{id};

my $pricing_plan_id = $db->insert('pricing_plans', {
    session_id => $session->id,
    plan_name => 'E2E Test Plan',
    plan_type => 'standard',
    amount => 300.00,
    installments_allowed => 1
}, { returning => 'id' })->hash->{id};

my $schedule = Registry::DAO::PaymentSchedule->create($db, {
    enrollment_id => $enrollment_id,
    pricing_plan_id => $pricing_plan_id,
    stripe_subscription_id => 'sub_e2e_test',
    total_amount => 300.00,
    installment_amount => 100.00,
    installment_count => 3,
    status => 'active'
});

subtest 'End-to-end installment payment schedule creation' => sub {
    plan tests => 5;

    ok $schedule, 'Payment schedule created successfully';
    isa_ok $schedule, 'Registry::DAO::PaymentSchedule';
    is $schedule->total_amount, '300.00', 'Total amount is correct';
    is $schedule->installment_count, 3, 'Installment count is correct';
    is $schedule->status, 'active', 'Schedule starts as active';
};

subtest 'End-to-end scheduled payment management' => sub {
    plan tests => 4;

    # Use the schedule created above

    my $payment = Registry::DAO::ScheduledPayment->create($db, {
        payment_schedule_id => $schedule->id,
        installment_number => 2,
        amount => 100.00,
        status => 'pending'
    });

    ok $payment, 'Scheduled payment created';
    is $payment->status, 'pending', 'Payment starts as pending';

    # Test status updates that would happen via webhooks
    $db->update('registry.scheduled_payments',
        { status => 'failed', failed_at => \'NOW()', failure_reason => 'card_declined' },
        { id => $payment->id }
    );

    my $updated_payment = $db->select('registry.scheduled_payments', '*', { id => $payment->id })->hash;
    is $updated_payment->{status}, 'failed', 'Payment can be marked as failed';
    is $updated_payment->{failure_reason}, 'card_declined', 'Failure reason is stored';
};