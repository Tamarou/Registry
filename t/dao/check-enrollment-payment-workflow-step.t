#!/usr/bin/env perl
# ABOUTME: Tests the CheckEnrollmentPayment decision step routes by enrollment total.
# ABOUTME: $0 total -> free-enrollment; >$0 -> payment, decoupled from STRIPE_SECRET_KEY.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $tenant = Test::Registry::Fixtures::create_tenant( $dao->db, {
    name => 'Test Check Payment Tenant',
    slug => 'test_check_payment',
} );
$dao->db->query( 'SELECT clone_schema(?)', 'test_check_payment' );

$dao = Registry::DAO->new( url => $test_db->uri, schema => 'test_check_payment' );
my $db = $dao->db;

my $location = Registry::DAO::Location->create( $db, {
    name         => 'Test Location',
    address_info => { street_address => '123 Main St', city => 'Test City', state => 'TS', postal_code => '12345' },
    metadata     => {},
} );
my $teacher = Registry::DAO::User->create( $db, {
    name => 'Test Teacher', username => 'testteacher', email => 'teacher@test.com', user_type => 'staff',
} );
my $project = Registry::DAO::Project->create( $db, { name => 'Test Project', metadata => {} } );
my $event = Registry::DAO::Event->create( $db, {
    time => '2024-07-01 10:00:00', duration => 120,
    location_id => $location->id, project_id => $project->id, teacher_id => $teacher->id,
    metadata => {}, capacity => 20,
} );

# Free session ($0 pricing) and paid session ($150).
my $free_session = Registry::DAO::Session->create( $db, {
    name => 'Free Session', start_date => '2024-07-02', end_date => '2024-07-09', status => 'published', metadata => {},
} );
$free_session->add_events( $db, $event->id );
Registry::DAO::PricingPlan->create( $db, {
    session_id => $free_session->id, plan_name => 'Free', plan_type => 'standard', amount => 0.00,
} );

my $paid_session = Registry::DAO::Session->create( $db, {
    name => 'Paid Session', start_date => '2024-07-16', end_date => '2024-07-23', status => 'published', metadata => {},
} );
$paid_session->add_events( $db, $event->id );
Registry::DAO::PricingPlan->create( $db, {
    session_id => $paid_session->id, plan_name => 'Standard', plan_type => 'standard', amount => 150.00,
} );

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Test Check Payment Workflow', slug => 'test-check-payment-workflow',
    description => 'Test workflow for the enrollment payment decision',
} );
my $selection = Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'session-selection',
    class => 'Registry::DAO::WorkflowSteps::MultiChildSessionSelection', description => 'Session selection',
} );
my $check = Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'check-enrollment-payment',
    class => 'Registry::DAO::WorkflowSteps::CheckEnrollmentPayment', description => 'Check if payment required',
    depends_on => $selection->id,
} );
my $payment = Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'payment',
    class => 'Registry::DAO::WorkflowSteps::Payment', description => 'Payment', depends_on => $check->id,
} );
my $free = Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'free-enrollment',
    class => 'Registry::DAO::WorkflowSteps::FreeEnrollment', description => 'Free enrollment', depends_on => $check->id,
} );
Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'complete',
    class => 'Registry::DAO::WorkflowStep', description => 'Complete', depends_on => $payment->id,
} );
$workflow->update( $db, { first_step => 'session-selection' }, { id => $workflow->id } );

my $parent = Registry::DAO::User->create( $db, {
    email => 'parent@example.com', username => 'testparent', password => 'password123',
    name => 'Test Parent', user_type => 'parent',
} );
my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Alice Smith', birth_date => '2016-03-15', grade => '3',
    medical_info => {}, emergency_contact => { name => 'Emergency', phone => '555-0123' },
} );

subtest 'a $0 enrollment routes to free-enrollment' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id            => $parent->id,
        children           => [ { id => $child->id } ],
        session_selections => { $child->id => $free_session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $free_session->id } ],
    } );
    my $step   = $workflow->get_step( $db, { slug => 'check-enrollment-payment' } );
    my $result = $step->process( $db, {}, $run );
    is $result->{next_step}, 'free-enrollment', 'routes to free-enrollment for a $0 total';
};

subtest 'a priced enrollment routes to payment' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id            => $parent->id,
        children           => [ { id => $child->id } ],
        session_selections => { $child->id => $paid_session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $paid_session->id } ],
    } );
    my $step   = $workflow->get_step( $db, { slug => 'check-enrollment-payment' } );
    my $result = $step->process( $db, {}, $run );
    is $result->{next_step}, 'payment', 'routes to payment for a >$0 total';
};

subtest 'free-enrollment step creates an active enrollment with no payment' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id          => $parent->id,
        enrollment_items => [ { child_id => $child->id, session_id => $free_session->id } ],
    } );
    my $step   = $workflow->get_step( $db, { slug => 'free-enrollment' } );
    my $result = $step->process( $db, {}, $run );
    is $result->{next_step}, 'complete', 'free-enrollment advances to complete';

    my $enrollment = $db->query(
        'SELECT status, payment_id FROM enrollments WHERE session_id = ? AND family_member_id = ?',
        $free_session->id, $child->id
    )->hash;
    ok $enrollment, 'enrollment row created';
    is $enrollment->{status},     'active', 'enrollment is active';
    is $enrollment->{payment_id}, undef,    'no payment associated';
};

done_testing;
