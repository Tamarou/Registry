#!/usr/bin/env perl
# ABOUTME: The Payment step enrolls a $0 program without the gateway, regardless of env.
# ABOUTME: Verifies payment-or-not is driven by pricing (total), not STRIPE_SECRET_KEY.

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
    name => 'Free By Total Tenant', slug => 'test_free_by_total',
} );
$dao->db->query( 'SELECT clone_schema(?)', 'test_free_by_total' );
$dao = Registry::DAO->new( url => $test_db->uri, schema => 'test_free_by_total' );
my $db = $dao->db;

my $location = Registry::DAO::Location->create( $db, {
    name => 'Loc', address_info => { street_address => '1 A', city => 'T', state => 'TS', postal_code => '12345' }, metadata => {},
} );
my $teacher = Registry::DAO::User->create( $db, {
    name => 'Teacher', username => 'tch_fbt', email => 'tch_fbt@test.com', user_type => 'staff',
} );
my $project = Registry::DAO::Project->create( $db, { name => 'Free Program', metadata => {} } );
my $event = Registry::DAO::Event->create( $db, {
    time => '2024-07-01 10:00:00', duration => 120,
    location_id => $location->id, project_id => $project->id, teacher_id => $teacher->id,
    metadata => {}, capacity => 20,
} );
my $session = Registry::DAO::Session->create( $db, {
    name => 'Free Session', start_date => '2024-07-02', end_date => '2024-07-09', status => 'published', metadata => {},
} );
$session->add_events( $db, $event->id );
Registry::DAO::PricingPlan->create( $db, {
    session_id => $session->id, plan_name => 'Free', plan_type => 'standard', amount => 0.00,
} );

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Free Reg', slug => 'free-reg', description => 'x',
} );
my $payment = Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'payment',
    class => 'Registry::DAO::WorkflowSteps::Payment', description => 'Payment',
} );
Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'complete',
    class => 'Registry::DAO::WorkflowStep', description => 'Complete', depends_on => $payment->id,
} );
$workflow->update( $db, { first_step => 'payment' }, { id => $workflow->id } );

my $parent = Registry::DAO::User->create( $db, {
    email => 'p@example.com', username => 'pfbt', password => 'password123', name => 'Parent', user_type => 'parent',
} );
my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Kid', birth_date => '2016-03-15', grade => '3',
    medical_info => {}, emergency_contact => { name => 'E', phone => '555-0123' },
} );

subtest 'a $0 program enrolls without Stripe even when STRIPE_SECRET_KEY is set' => sub {
    # A configured (test) Stripe key would normally send paid registrations to the
    # gateway; a $0 total must still skip it entirely.
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy_for_free_path';

    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id            => $parent->id,
        children           => [ { id => $child->id } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
    } );

    my $step   = $workflow->get_step( $db, { slug => 'payment' } );
    my $result = $step->process( $db, { agreeTerms => 1 }, $run );

    is $result->{next_step}, 'complete', 'advances to complete (no payment page)';

    my $enrollment = $db->query(
        'SELECT status, payment_id FROM enrollments WHERE session_id = ? AND family_member_id = ?',
        $session->id, $child->id
    )->hash;
    ok $enrollment, 'enrollment created';
    is $enrollment->{status},     'active', 'enrollment is active';
    is $enrollment->{payment_id}, undef,    'no payment associated (Stripe skipped)';
};

done_testing;
