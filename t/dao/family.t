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

use Registry::DAO::Family;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant (in registry schema)
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Organization',
    slug => 'test_org',
});

# Create the tenant schema with all required tables
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create test parent users (in registry schema)
my $parent1 = Test::Registry::Fixtures::create_user($db, {
    username => 'parent1',
    password => 'password123',
    user_type => 'parent',
});

my $parent2 = Test::Registry::Fixtures::create_user($db, {
    username => 'parent2', 
    password => 'password123',
    user_type => 'parent',
});

# Copy users to tenant schema
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent1->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent2->id);

# Switch to tenant schema for family operations
$db = $db->schema($tenant->slug);

subtest 'Add child to family' => sub {
    my $child = Registry::DAO::Family->add_child($db, $parent1->id, {
        child_name => 'Emma Johnson',
        birth_date => '2015-03-15',
        grade => '3',
        medical_info => {
            allergies => ['peanuts'],
            medications => [],
        },
        emergency_contact => {
            name => 'Grandma Johnson',
            phone => '555-1234',
        },
    });
    
    ok($child, 'Child added to family');
    is($child->family_id, $parent1->id, 'Correct family ID');
    is($child->child_name, 'Emma Johnson', 'Child name set');
    is($child->birth_date, '2015-03-15', 'Birth date set');
    is($child->grade, '3', 'Grade set');
    is_deeply($child->medical_info->{allergies}, ['peanuts'], 'Medical info stored');
    is($child->emergency_contact->{name}, 'Grandma Johnson', 'Emergency contact stored');
};

subtest 'List children in family' => sub {
    # Add another child
    Registry::DAO::Family->add_child($db, $parent1->id, {
        child_name => 'Liam Johnson',
        birth_date => '2017-08-22',
        grade => '1',
    });
    
    my $children = Registry::DAO::Family->list_children($db, $parent1->id);
    
    is(@$children, 2, 'Two children in family');
    is($children->[0]->child_name, 'Emma Johnson', 'First child (older) listed first');
    is($children->[1]->child_name, 'Liam Johnson', 'Second child (younger) listed second');
};

subtest 'Update child information' => sub {
    my $children = Registry::DAO::Family->list_children($db, $parent1->id);
    my $child = $children->[0];
    
    Registry::DAO::Family->update_child($db, $child->id, {
        grade => '4',
        medical_info => {
            allergies => ['peanuts', 'shellfish'],
            medications => ['inhaler'],
        },
    });
    
    my $updated = Registry::DAO::FamilyMember->find($db, { id => $child->id });
    is($updated->grade, '4', 'Grade updated');
    is_deeply($updated->medical_info->{allergies}, ['peanuts', 'shellfish'], 'Medical info updated');
};

subtest 'Age calculation' => sub {
    my $child = Registry::DAO::Family->add_child($db, $parent2->id, {
        child_name => 'Test Child',
        birth_date => '2018-01-01',
    });
    
    # Mock a specific date for testing (2024-01-01)
    my $test_date = 1704067200; # 2024-01-01 00:00:00 UTC
    my $age = $child->age($test_date);
    is($age, 6, 'Age calculated correctly');
    
    # Test edge case - birthday hasn't happened yet this year
    $test_date = 1703980800; # 2023-12-31 00:00:00 UTC
    $age = $child->age($test_date);
    is($age, 5, 'Age correct when birthday hasn\'t happened yet');
};

subtest 'Age eligibility check' => sub {
    my $child = Registry::DAO::FamilyMember->find($db, {
        child_name => 'Test Child',
        family_id => $parent2->id,
    });
    
    # Mock date where child is 6 years old
    my $test_date = 1704067200; # 2024-01-01
    
    ok($child->is_age_eligible(5, 10, $test_date), 'Child eligible for 5-10 age range');
    ok($child->is_age_eligible(6, 10, $test_date), 'Child eligible at minimum age');
    ok($child->is_age_eligible(3, 6, $test_date), 'Child eligible at maximum age');
    ok(!$child->is_age_eligible(7, 10, $test_date), 'Child not eligible when too young');
    ok(!$child->is_age_eligible(3, 5, $test_date), 'Child not eligible when too old');
};

subtest 'Grade eligibility check' => sub {
    my $child = Registry::DAO::Family->add_child($db, $parent2->id, {
        child_name => 'Grade Test Child',
        birth_date => '2016-01-01',
        grade => '2',
    });
    
    ok($child->is_grade_eligible(['1', '2', '3']), 'Child eligible for grade range');
    ok($child->is_grade_eligible(['2']), 'Child eligible for exact grade');
    ok(!$child->is_grade_eligible(['3', '4', '5']), 'Child not eligible for different grades');
    ok($child->is_grade_eligible([]), 'All children eligible when no grades specified');
};

subtest 'Find eligible children' => sub {
    # Clear existing children for parent2
    $db->db->delete('family_members', { family_id => $parent2->id });
    
    # Add children with different ages and grades
    Registry::DAO::Family->add_child($db, $parent2->id, {
        child_name => 'Young Child',
        birth_date => '2019-01-01',
        grade => 'K',
    });
    
    Registry::DAO::Family->add_child($db, $parent2->id, {
        child_name => 'Middle Child',
        birth_date => '2016-01-01',
        grade => '2',
    });
    
    Registry::DAO::Family->add_child($db, $parent2->id, {
        child_name => 'Older Child',
        birth_date => '2013-01-01',
        grade => '5',
    });
    
    # Test date where children are 5, 8, and 11
    my $test_date = 1704067200; # 2024-01-01
    
    # Find children aged 7-10
    my $eligible = Registry::DAO::Family->find_eligible_children($db, $parent2->id, {
        min_age => 7,
        max_age => 10,
        as_of_date => $test_date,
    });
    
    is(@$eligible, 1, 'One child in age range');
    is($eligible->[0]->child_name, 'Middle Child', 'Correct child found');
    
    # Find children in grades 2-5
    $eligible = Registry::DAO::Family->find_eligible_children($db, $parent2->id, {
        grades => ['2', '3', '4', '5'],
    });
    
    is(@$eligible, 2, 'Two children in grade range');
};

subtest 'Multiple children check' => sub {
    ok(Registry::DAO::Family->has_multiple_children($db, $parent1->id), 
       'Parent 1 has multiple children');
    
    # Create parent with single child (switch back to registry schema for user creation)
    my $registry_db = $db->schema('registry');
    my $single_parent = Test::Registry::Fixtures::create_user($registry_db, {
        username => 'single_parent',
        password => 'password123',
        user_type => 'parent',
    });
    
    # Copy user to tenant schema
    $registry_db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', 'test_org', $single_parent->id);
    
    Registry::DAO::Family->add_child($db, $single_parent->id, {
        child_name => 'Only Child',
        birth_date => '2015-01-01',
    });
    
    ok(!Registry::DAO::Family->has_multiple_children($db, $single_parent->id),
       'Parent has only one child');
};

subtest 'Sibling discount eligibility' => sub {
    # Create test session
    my $session = Test::Registry::Fixtures::create_session($db, {
        name => 'Test Session',
    });
    
    # Enroll first child
    my $children = Registry::DAO::Family->list_children($db, $parent1->id);
    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id,
        student_id => $parent1->id, # Using parent as student for simplicity
        family_member_id => $children->[0]->id,
        status => 'active',
    });
    
    ok(!Registry::DAO::Family->sibling_discount_eligible($db, $parent1->id, $session->id),
       'Not eligible with one child enrolled');
    
    # Enroll second child
    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id,
        student_id => $parent1->id,
        family_member_id => $children->[1]->id,
        status => 'active',
    });
    
    ok(Registry::DAO::Family->sibling_discount_eligible($db, $parent1->id, $session->id),
       'Eligible with two children enrolled');
};

subtest 'Family member relations' => sub {
    my $children = Registry::DAO::Family->list_children($db, $parent1->id);
    my $child = $children->[0];
    
    # Test family relation
    my $family = $child->family($db);
    is($family->id, $parent1->id, 'Family relation works');
    
    # Test enrollments relation
    my $enrollments = $child->enrollments($db);
    ok($enrollments, 'Can retrieve enrollments');
    isa_ok($enrollments, 'ARRAY', 'Enrollments is array');
};

subtest 'Backward compatibility' => sub {
    # Enrollments should work with either student_id or family_member_id
    my $session = Test::Registry::Fixtures::create_session($db, {
        name => 'Backward Compatible Session',
    });
    
    # Create enrollment with just student_id (old style)
    my $old_enrollment = Registry::DAO::Enrollment->create($db, {
        session_id => $session->id,
        student_id => $parent1->id,
        status => 'active',
    });
    
    ok($old_enrollment, 'Can create enrollment without family_member_id');
    ok(!$old_enrollment->family_member_id, 'No family member ID set');
    
    # Create enrollment with family_member_id (new style)
    my $children = Registry::DAO::Family->list_children($db, $parent1->id);
    my $new_enrollment = Registry::DAO::Enrollment->create($db, {
        session_id => $session->id,
        student_id => $parent1->id,
        family_member_id => $children->[0]->id,
        status => 'active',
    });
    
    ok($new_enrollment, 'Can create enrollment with family_member_id');
    ok($new_enrollment->family_member_id, 'Family member ID set');
    
    my $family_member = $new_enrollment->family_member($db);
    is($family_member->id, $children->[0]->id, 'Can retrieve family member');
};

done_testing;