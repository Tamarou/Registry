#!/usr/bin/env perl
use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Exception;
use Test::Deep;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::ProgramType;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Organization',
    slug => 'test-org',
});

# Switch to tenant schema
$db->schema($tenant->slug);

subtest 'Create program type' => sub {
    my $program_type = Registry::DAO::ProgramType->create($db, {
        name => 'Test Program',
        config => {
            enrollment_rules => {
                same_session_for_siblings => 1
            },
            standard_times => {
                monday => '16:00',
                tuesday => '16:00'
            },
            session_pattern => 'weekly_for_x_weeks'
        }
    });
    
    ok($program_type, 'Program type created');
    is($program_type->name, 'Test Program', 'Name set correctly');
    is($program_type->slug, 'test-program', 'Slug generated from name');
    ok($program_type->id, 'ID assigned');
    
    # Check config
    is_deeply(
        $program_type->enrollment_rules,
        { same_session_for_siblings => 1 },
        'Enrollment rules stored correctly'
    );
    
    is_deeply(
        $program_type->standard_times,
        { monday => '16:00', tuesday => '16:00' },
        'Standard times stored correctly'
    );
    
    is($program_type->session_pattern, 'weekly_for_x_weeks', 'Session pattern stored');
};

subtest 'Create with explicit slug' => sub {
    my $program_type = Registry::DAO::ProgramType->create($db, {
        name => 'Another Program',
        slug => 'custom-slug',
        config => {}
    });
    
    is($program_type->slug, 'custom-slug', 'Custom slug used');
};

subtest 'Find program type' => sub {
    my $created = Registry::DAO::ProgramType->create($db, {
        name => 'Find Me',
        config => { test => 'data' }
    });
    
    my $found = Registry::DAO::ProgramType->find($db, { id => $created->id });
    ok($found, 'Program type found by ID');
    is($found->name, 'Find Me', 'Correct program type retrieved');
    is_deeply($found->config, { test => 'data' }, 'Config retrieved correctly');
};

subtest 'Find by slug' => sub {
    my $created = Registry::DAO::ProgramType->create($db, {
        name => 'Slug Test',
        slug => 'slug-test',
        config => {}
    });
    
    my $found = Registry::DAO::ProgramType->find_by_slug($db, 'slug-test');
    ok($found, 'Found by slug');
    is($found->id, $created->id, 'Correct program type found');
};

subtest 'List program types' => sub {
    # Clear existing data
    $db->delete('program_types');
    
    # Create some program types
    Registry::DAO::ProgramType->create($db, {
        name => "Program $_",
        config => {}
    }) for 1..3;
    
    my $list = Registry::DAO::ProgramType->list($db);
    is(@$list, 3, 'All program types listed');
    
    # Check they're all ProgramType objects
    isa_ok($_, 'Registry::DAO::ProgramType') for @$list;
};

subtest 'Update program type' => sub {
    my $program_type = Registry::DAO::ProgramType->create($db, {
        name => 'Update Me',
        config => { version => 1 }
    });
    
    $program_type->update($db, {
        name => 'Updated Name',
        config => { version => 2, new_field => 'value' }
    });
    
    my $updated = Registry::DAO::ProgramType->find($db, { id => $program_type->id });
    is($updated->name, 'Updated Name', 'Name updated');
    is_deeply(
        $updated->config,
        { version => 2, new_field => 'value' },
        'Config updated'
    );
};

subtest 'Helper methods' => sub {
    my $program_type = Registry::DAO::ProgramType->create($db, {
        name => 'Helper Test',
        config => {
            enrollment_rules => {
                same_session_for_siblings => 1
            },
            standard_times => {
                monday => '15:00',
                wednesday => '14:00'
            },
            session_pattern => 'daily_for_x_days'
        }
    });
    
    # Test helper methods
    ok($program_type->same_session_for_siblings, 'Sibling rule helper works');
    is($program_type->standard_time_for_day('monday'), '15:00', 'Get time for specific day');
    is($program_type->standard_time_for_day('MONDAY'), '15:00', 'Case insensitive day lookup');
    is($program_type->standard_time_for_day('tuesday'), undef, 'Returns undef for unset day');
    is($program_type->session_pattern, 'daily_for_x_days', 'Pattern helper works');
};

subtest 'Seed data exists' => sub {
    # Switch back to registry schema to check seed data
    $db->schema('registry');
    
    my $afterschool = Registry::DAO::ProgramType->find_by_slug($db, 'afterschool');
    ok($afterschool, 'After school program type exists');
    is($afterschool->name, 'After School Program', 'Correct name');
    ok($afterschool->same_session_for_siblings, 'Siblings must be in same session');
    
    my $summer = Registry::DAO::ProgramType->find_by_slug($db, 'summer-camp');
    ok($summer, 'Summer camp program type exists');
    is($summer->name, 'Summer Camp', 'Correct name');
    ok(!$summer->same_session_for_siblings, 'Siblings can be in different sessions');
};

done_testing;