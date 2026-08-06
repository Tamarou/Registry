#!/usr/bin/env perl
# ABOUTME: Tests that GenerateEvents creates a session-linked PricingPlan from pricing_override.
# ABOUTME: Without this, generated sessions have no price and never appear on the storefront (#218).

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::GenerateEvents;
use Registry::DAO::User;
use Registry::DAO::Project;
use Registry::DAO::Location;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $tenant = Test::Registry::Fixtures::create_tenant( $dao->db, {
    name => 'Test Generate Events Pricing', slug => 'test_gen_pricing',
} );
$dao->db->query( 'SELECT clone_schema(?)', 'test_gen_pricing' );
$dao = Registry::DAO->new( url => $test_db->uri, schema => 'test_gen_pricing' );
my $db = $dao->db;

my $location = Registry::DAO::Location->create( $db, {
    name         => 'Test Location',
    address_info => { street_address => '1 Main', city => 'Town', state => 'TS', postal_code => '12345' },
    metadata     => {},
} );
my $teacher = Registry::DAO::User->create( $db, {
    name => 'Teacher', username => 'teacher_gp', email => 'teacher_gp@test.com', user_type => 'staff',
} );
my $project = Registry::DAO::Project->create( $db, { name => 'Free Program', metadata => {} } );

# Build a workflow with the generate-events step so we can call its methods.
my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Test GenEvents', slug => 'test-gen-events', description => 'test',
} );
Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'generate-events',
    class => 'Registry::DAO::WorkflowSteps::GenerateEvents', description => 'Generate events',
} );
my $step = $workflow->get_step( $db, { slug => 'generate-events' } );

my $project_data = {
    project_id          => $project->id,
    project_name        => $project->name,
    project_description => 'A free program',
};
my $location_config = {
    id               => $location->id,
    name             => $location->name,
    capacity         => 16,
    schedule         => { monday => '15:00' },
    pricing_override => 0,            # free
    notes            => '',
};
my $params = { start_date => time(), duration_weeks => 1 };

my $result = $step->create_session_for_location( $db, $project_data, $location_config, $params, $teacher->id );

ok !$result->{error}, 'session generated without error'
    or diag $result->{error};
ok $result->{session_id}, 'a session was created';

# Pricing plans live in the tenant's own schema: PricingPlan::create uses the
# unqualified table so the connection's search_path (here: test_gen_pricing)
# determines where the plan is written, alongside its session.
my $plan = $db->query(
    'SELECT * FROM pricing_plans WHERE session_id = ?', $result->{session_id}
)->hash;

ok $plan, 'a PricingPlan is linked to the generated session';
is( ( $plan->{amount_cents} // -1 ) + 0, 0, 'plan amount matches the pricing_override (free)' );

done_testing;
