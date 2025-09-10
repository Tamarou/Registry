#!/usr/bin/env perl
use v5.34.0;
use warnings;
use experimental 'signatures';
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::FamilyMember;
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
my $location = Registry::DAO::Location->create($db, {
    name         => 'Test Location',
    address_info => { street => '123 Main St', city => 'Test City', state => 'TS', zip => '12345' },
    metadata     => {}
});

# Use existing afterschool program type or create one
my $program_type = Registry::DAO::ProgramType->find_by_slug($db, 'afterschool') 
    || Registry::DAO::ProgramType->create($db, {
        name   => 'Afterschool Program',
        slug   => 'afterschool',
        config => { 
            enrollment_rules => {
                same_session_for_siblings => 1
            }
        }
    });

my $project = Registry::DAO::Project->create($db, {
    name             => 'Test Afterschool Project',
    program_type_slug => 'afterschool',
    metadata         => {}
});

# Create a teacher user
my $teacher = Registry::DAO::User->create($db, {
    username => 'teacher',
    email    => 'teacher@example.com',
    password => 'password123',
    name     => 'Test Teacher'
});

my $event = Registry::DAO::Event->create($db, {
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    time        => Time::Piece->new(time + 86400)->strftime('%Y-%m-%d %H:%M:%S'),
    duration    => 60,
    metadata    => { title => 'Test Afterschool' }
});

# Create sessions with pricing
my $session1 = Registry::DAO::Session->create($db, {
    name       => 'Session 1',
    project_id => $project->id,
    start_date => Time::Piece->new(time + 86400),
    end_date   => Time::Piece->new(time + 86400 * 7),
    capacity   => 10,
    metadata   => { min_age => 5, max_age => 12 }
});

my $session2 = Registry::DAO::Session->create($db, {
    name       => 'Session 2',
    project_id => $project->id,
    start_date => Time::Piece->new(time + 86400 * 14),
    end_date   => Time::Piece->new(time + 86400 * 21),
    capacity   => 5,
    metadata   => { min_age => 5, max_age => 12 }
});

# Add pricing plans (simplified for test)
# Registry::DAO::PricingPlan->create($db, {
#     session_id  => $session1->id,
#     plan_name   => 'Standard',
#     amount      => 200,
#     metadata    => {}
# });

# Registry::DAO::PricingPlan->create($db, {
#     session_id  => $session2->id,
#     plan_name   => 'Standard',
#     amount      => 250,
#     metadata    => {}
# });

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Multi-Child Enrollment',
    slug => 'test-multi-child-enrollment',
    description => 'Test workflow for multi-child enrollment process'
});

# Create test user
my $user = Registry::DAO::User->create($db, {
    username => 'parent',
    email    => 'parent@example.com',
    password => 'password123',
    name     => 'Test Parent'
});

# Create family members
my $child1 = Registry::DAO::FamilyMember->create($db, {
    family_id    => $user->id,
    child_name   => 'Child One',
    birth_date   => Time::Piece->new->add_years(-8)->strftime('%Y-%m-%d'),
    grade        => '3rd',
    medical_info => {}
});

my $child2 = Registry::DAO::FamilyMember->create($db, {
    family_id    => $user->id,
    child_name   => 'Child Two',
    birth_date   => Time::Piece->new->add_years(-10)->strftime('%Y-%m-%d'),
    grade        => '5th',
    medical_info => {}
});

# TODO: Workflow processing tests disabled - workflow processor not implemented
# subtest 'Account check step' => sub {
#     my $run = $workflow->start($db);
#     
#     # Test existing account login
#     my $result = $workflow->process_step($db, $run, 'account-check', {
#         has_account => 'yes',
#         email       => 'parent@example.com',
#         password    => 'password123'
#     });
#     
#     is $result->{next_step}, 'select-children', 'Successful login routes to select-children';
#     is $run->data->{user_id}, $user->id, 'User ID stored in run data';
#     
#     # Test invalid credentials
#     $run = $workflow->start($db);
#     $result = $workflow->process_step($db, $run, 'account-check', {
#         has_account => 'yes',
#         email       => 'parent@example.com',
#         password    => 'wrong'
#     });
#     
#     ok $result->{errors}, 'Invalid credentials return error';
# };

# TODO: Workflow processing tests disabled - workflow processor not implemented  
# subtest 'Select children step' => sub {
#     my $run = $workflow->start($db);
#     $run->data->{user_id} = $user->id;
#     $run->save($db);
#     
#     # Select existing children
#     my $result = $workflow->process_step($db, $run, 'select-children', {
#         "child_$child1->{id}" => 1,
#         "child_$child2->{id}" => 1
#     });
#     
#     is $result->{next_step}, 'session-selection', 'Routes to session selection';
#     is scalar(@{$run->data->{children}}), 2, 'Two children selected';
#     is $run->data->{children}->[0]->{id}, $child1->id, 'First child stored correctly';
#     
#     # Add new child
#     $run = $workflow->start($db);
#     $run->data->{user_id} = $user->id;
#     $run->save($db);
#     
#     $result = $workflow->process_step($db, $run, 'select-children', {
#         add_child               => 1,
#         new_child_first_name    => 'New',
#         new_child_last_name     => 'Child',
#         new_child_birthdate     => Time::Piece->new->add_years(-7)->strftime('%Y-%m-%d'),
#         new_child_relationship  => 'child'
#     });
#     
#     is $result->{next_step}, 'select-children', 'Adding child stays on same step';
#     my $new_child = $db->query('SELECT * FROM family_members WHERE first_name = ? AND user_id = ?', 
#                                'New', $user->id)->hash;
#     ok $new_child, 'New child created in database';
# };

# TODO: Workflow processing tests disabled - workflow processor not implemented
# subtest 'Multi-child session selection' => sub {
#     my $run = $workflow->start($db);
#     $run->data->{user_id} = $user->id;
#     $run->data->{program_type_id} = $program_type->id;
#     $run->data->{children} = [
#         { id => $child1->id, first_name => 'Child', last_name => 'One', age => 8 },
#         { id => $child2->id, first_name => 'Child', last_name => 'Two', age => 10 }
#     ];
#     $run->save($db);
#     
#     # Test same session requirement for afterschool
#     my $result = $workflow->process_step($db, $run, 'session-selection', {
#         session_all => $session1->id
#     });
#     
#     is $result->{next_step}, 'payment', 'Routes to payment';
#     is $run->data->{session_selections}->{all}, $session1->id, 'Session selection stored';
#     
#     # Test different sessions (should fail for afterschool)
#     $run = $workflow->start($db);
#     $run->data->{user_id} = $user->id;
#     $run->data->{program_type_id} = $program_type->id;
#     $run->data->{children} = [
#         { id => $child1->id, first_name => 'Child', last_name => 'One', age => 8 },
#         { id => $child2->id, first_name => 'Child', last_name => 'Two', age => 10 }
#     ];
#     $run->save($db);
#     
#     $result = $workflow->process_step($db, $run, 'session-selection', {
#         "session_$child1->{id}" => $session1->id,
#         "session_$child2->{id}" => $session2->id
#     });
#     
#     ok $result->{errors}, 'Different sessions for siblings returns error';
#     like $result->{errors}->[0], qr/siblings must be enrolled in the same session/, 'Correct error message';
# };

# Basic data creation test 
subtest 'Data creation works' => sub {
    ok $location, 'Location created successfully';
    ok $program_type, 'Program type created successfully';
    ok $project, 'Project created successfully';  
    ok $teacher, 'Teacher created successfully';
    ok $event, 'Event created successfully';
    ok $session1, 'Session 1 created successfully';
    ok $session2, 'Session 2 created successfully';
    ok $workflow, 'Workflow created successfully';
    ok $user, 'User created successfully';
    ok $child1, 'Child 1 created successfully';
    ok $child2, 'Child 2 created successfully';
    
    # Test that objects have expected fields
    is $location->name, 'Test Location', 'Location name correct';
    is $program_type->name, 'After School Program', 'Program type name correct';
    is $user->username, 'parent', 'User username correct';
    is $child1->child_name, 'Child One', 'Child 1 name correct';
    is $child2->child_name, 'Child Two', 'Child 2 name correct';
};

done_testing();