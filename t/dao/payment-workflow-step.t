#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Time::Piece;
use Mojo::JSON qw(encode_json);

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db;

# Create test tenant and set search path
$db->query(q{
    INSERT INTO registry.tenants (id, name, slug, config, status)
    VALUES (1, 'Test Tenant', 'test-tenant', '{}', 'active')
});
$db->query("SET search_path TO tenant_1, registry, public");

# Create test data
my $location = Registry::DAO::Location->new(
    name    => 'Test Location',
    address => encode_json({ street => '123 Main St', city => 'Test City', state => 'TS', zip => '12345' }),
    config  => {}
)->save($db);

my $event = Registry::DAO::Event->new(
    name        => 'Test Event',
    location_id => $location->id,
    config      => {}
)->save($db);

my $project = Registry::DAO::Project->new(
    name      => 'Test Project',
    event_id  => $event->id,
    config    => {}
)->save($db);

my $session = Registry::DAO::Session->new(
    name       => 'Test Session',
    project_id => $project->id,
    start_date => Time::Piece->new(time + 86400),
    end_date   => Time::Piece->new(time + 86400 * 7),
    capacity   => 20,
    config     => {}
)->save($db);

Registry::DAO::PricingPlan->new(
    session_id  => $session->id,
    name        => 'Standard',
    base_price  => 150,
    tier_order  => 1,
    config      => {}
)->save($db);

# Create workflow with payment step
my $workflow = Registry::DAO::Workflow->new(
    name   => 'Test Payment Workflow',
    config => {
        steps => [
            { id => 'payment', type => 'payment', class => 'Registry::DAO::WorkflowSteps::Payment' },
            { id => 'complete', type => 'form' }
        ]
    }
)->save($db);

# Create test user and children
my $user = Registry::DAO::User->new(
    email    => 'parent@example.com',
    password => 'password123',
    profile  => { name => 'Test Parent' }
)->save($db);

my $child1 = Registry::DAO::Family->new(
    user_id      => $user->id,
    first_name   => 'Alice',
    last_name    => 'Smith',
    birthdate    => Time::Piece->new->add_years(-8)->strftime('%Y-%m-%d'),
    relationship => 'child',
    medical_info => {}
)->save($db);

my $child2 = Registry::DAO::Family->new(
    user_id      => $user->id,
    first_name   => 'Bob',
    last_name    => 'Smith',
    birthdate    => Time::Piece->new->add_years(-10)->strftime('%Y-%m-%d'),
    relationship => 'child',
    medical_info => {}
)->save($db);

subtest 'Payment step data preparation' => sub {
    my $run = $workflow->start($db);
    
    # Set up run data as if coming from previous steps
    $run->data->{user_id} = $user->id;
    $run->data->{children} = [
        { id => $child1->id, first_name => 'Alice', last_name => 'Smith', age => 8 },
        { id => $child2->id, first_name => 'Bob', last_name => 'Smith', age => 10 }
    ];
    $run->data->{session_selections} = {
        $child1->id => $session->id,
        $child2->id => $session->id
    };
    $run->save($db);
    
    # Process step without form data to get payment page
    my $result = $workflow->process_step($db, $run, 'payment', {});
    
    is $result->{next_step}, 'payment', 'Stays on payment step';
    ok $result->{data}, 'Payment data prepared';
    is $result->{data}->{total}, 300, 'Total calculated correctly (150 * 2)';
    is scalar(@{$result->{data}->{items}}), 2, 'Two line items prepared';
};

subtest 'Payment creation without Stripe' => sub {
    my $run = $workflow->start($db);
    
    # Set up run data
    $run->data->{user_id} = $user->id;
    $run->data->{children} = [
        { id => $child1->id, first_name => 'Alice', last_name => 'Smith', age => 8 }
    ];
    $run->data->{session_selections} = {
        $child1->id => $session->id
    };
    $run->save($db);
    
    # Skip actual Stripe integration
    local $ENV{STRIPE_SECRET_KEY} = undef;
    
    # Process with agreement checked
    my $result = $workflow->process_step($db, $run, 'payment', {
        agreeTerms => 1
    });
    
    # Without Stripe key, it should fail gracefully
    ok $result->{errors} || $result->{next_step} eq 'payment', 
       'Payment step handles missing Stripe key';
};

subtest 'Enrollment creation on successful payment' => sub {
    skip "Cannot test enrollment creation without mocking Stripe", 1;
    
    # This would require mocking the Stripe API response
    # In a real test environment, you'd use Test::MockModule or similar
};

done_testing();