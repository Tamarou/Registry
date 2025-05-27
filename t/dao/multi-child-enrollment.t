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
use Registry::DAO::ProgramType;
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

my $program_type = Registry::DAO::ProgramType->new(
    name                    => 'Afterschool Program',
    slug                    => 'afterschool',
    config                  => { same_session_for_siblings => 1 },
    same_session_for_siblings => 1
)->save($db);

my $event = Registry::DAO::Event->new(
    name        => 'Test Afterschool',
    location_id => $location->id,
    config      => {}
)->save($db);

my $project = Registry::DAO::Project->new(
    name             => 'Test Afterschool Project',
    event_id         => $event->id,
    program_type_id  => $program_type->id,
    program_type_slug => 'afterschool',
    config           => {}
)->save($db);

# Create sessions with pricing
my $session1 = Registry::DAO::Session->new(
    name       => 'Session 1',
    project_id => $project->id,
    start_date => Time::Piece->new(time + 86400),
    end_date   => Time::Piece->new(time + 86400 * 7),
    capacity   => 10,
    min_age    => 5,
    max_age    => 12,
    config     => {}
)->save($db);

my $session2 = Registry::DAO::Session->new(
    name       => 'Session 2',
    project_id => $project->id,
    start_date => Time::Piece->new(time + 86400 * 14),
    end_date   => Time::Piece->new(time + 86400 * 21),
    capacity   => 5,
    min_age    => 5,
    max_age    => 12,
    config     => {}
)->save($db);

# Add pricing plans
Registry::DAO::PricingPlan->new(
    session_id  => $session1->id,
    name        => 'Standard',
    base_price  => 200,
    tier_order  => 1,
    config      => {}
)->save($db);

Registry::DAO::PricingPlan->new(
    session_id  => $session2->id,
    name        => 'Standard',
    base_price  => 250,
    tier_order  => 1,
    config      => {}
)->save($db);

# Create workflow
my $workflow = Registry::DAO::Workflow->new(
    name   => 'Test Multi-Child Enrollment',
    config => {
        steps => [
            { id => 'account-check', type => 'account-check' },
            { id => 'select-children', type => 'select-children' },
            { id => 'session-selection', type => 'multi-child-session-selection' },
            { id => 'payment', type => 'form' },
            { id => 'complete', type => 'form' }
        ]
    }
)->save($db);

# Create test user
my $user = Registry::DAO::User->new(
    email    => 'parent@example.com',
    password => 'password123',
    profile  => { name => 'Test Parent' }
)->save($db);

# Create family members
my $child1 = Registry::DAO::Family->new(
    user_id      => $user->id,
    first_name   => 'Child',
    last_name    => 'One',
    birthdate    => Time::Piece->new->add_years(-8)->strftime('%Y-%m-%d'),
    relationship => 'child',
    medical_info => {}
)->save($db);

my $child2 = Registry::DAO::Family->new(
    user_id      => $user->id,
    first_name   => 'Child',
    last_name    => 'Two',
    birthdate    => Time::Piece->new->add_years(-10)->strftime('%Y-%m-%d'),
    relationship => 'child',
    medical_info => {}
)->save($db);

subtest 'Account check step' => sub {
    my $run = $workflow->start($db);
    
    # Test existing account login
    my $result = $workflow->process_step($db, $run, 'account-check', {
        has_account => 'yes',
        email       => 'parent@example.com',
        password    => 'password123'
    });
    
    is $result->{next_step}, 'select-children', 'Successful login routes to select-children';
    is $run->data->{user_id}, $user->id, 'User ID stored in run data';
    
    # Test invalid credentials
    $run = $workflow->start($db);
    $result = $workflow->process_step($db, $run, 'account-check', {
        has_account => 'yes',
        email       => 'parent@example.com',
        password    => 'wrong'
    });
    
    ok $result->{errors}, 'Invalid credentials return error';
};

subtest 'Select children step' => sub {
    my $run = $workflow->start($db);
    $run->data->{user_id} = $user->id;
    $run->save($db);
    
    # Select existing children
    my $result = $workflow->process_step($db, $run, 'select-children', {
        "child_$child1->{id}" => 1,
        "child_$child2->{id}" => 1
    });
    
    is $result->{next_step}, 'session-selection', 'Routes to session selection';
    is scalar(@{$run->data->{children}}), 2, 'Two children selected';
    is $run->data->{children}->[0]->{id}, $child1->id, 'First child stored correctly';
    
    # Add new child
    $run = $workflow->start($db);
    $run->data->{user_id} = $user->id;
    $run->save($db);
    
    $result = $workflow->process_step($db, $run, 'select-children', {
        add_child               => 1,
        new_child_first_name    => 'New',
        new_child_last_name     => 'Child',
        new_child_birthdate     => Time::Piece->new->add_years(-7)->strftime('%Y-%m-%d'),
        new_child_relationship  => 'child'
    });
    
    is $result->{next_step}, 'select-children', 'Adding child stays on same step';
    my $new_child = $db->query('SELECT * FROM family_members WHERE first_name = ? AND user_id = ?', 
                               'New', $user->id)->hash;
    ok $new_child, 'New child created in database';
};

subtest 'Multi-child session selection' => sub {
    my $run = $workflow->start($db);
    $run->data->{user_id} = $user->id;
    $run->data->{program_type_id} = $program_type->id;
    $run->data->{children} = [
        { id => $child1->id, first_name => 'Child', last_name => 'One', age => 8 },
        { id => $child2->id, first_name => 'Child', last_name => 'Two', age => 10 }
    ];
    $run->save($db);
    
    # Test same session requirement for afterschool
    my $result = $workflow->process_step($db, $run, 'session-selection', {
        session_all => $session1->id
    });
    
    is $result->{next_step}, 'payment', 'Routes to payment';
    is $run->data->{session_selections}->{all}, $session1->id, 'Session selection stored';
    
    # Test different sessions (should fail for afterschool)
    $run = $workflow->start($db);
    $run->data->{user_id} = $user->id;
    $run->data->{program_type_id} = $program_type->id;
    $run->data->{children} = [
        { id => $child1->id, first_name => 'Child', last_name => 'One', age => 8 },
        { id => $child2->id, first_name => 'Child', last_name => 'Two', age => 10 }
    ];
    $run->save($db);
    
    $result = $workflow->process_step($db, $run, 'session-selection', {
        "session_$child1->{id}" => $session1->id,
        "session_$child2->{id}" => $session2->id
    });
    
    ok $result->{errors}, 'Different sessions for siblings returns error';
    like $result->{errors}->[0], qr/siblings must be enrolled in the same session/, 'Correct error message';
};

subtest 'Capacity validation' => sub {
    # Fill session to near capacity
    for (1..9) {
        $db->query('INSERT INTO enrollments (session_id, user_id, status) VALUES (?, ?, ?)',
                   $session1->id, $user->id, 'enrolled');
    }
    
    my $run = $workflow->start($db);
    $run->data->{user_id} = $user->id;
    $run->data->{program_type_id} = $program_type->id;
    $run->data->{children} = [
        { id => $child1->id, first_name => 'Child', last_name => 'One', age => 8 },
        { id => $child2->id, first_name => 'Child', last_name => 'Two', age => 10 }
    ];
    $run->save($db);
    
    # Try to enroll 2 children when only 1 spot left
    my $result = $workflow->process_step($db, $run, 'session-selection', {
        session_all => $session1->id
    });
    
    ok $result->{errors}, 'Insufficient capacity returns error';
    like $result->{errors}->[0], qr/not enough capacity/, 'Correct capacity error';
};

done_testing();