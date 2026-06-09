#!/usr/bin/env perl
# ABOUTME: Verifies Attendance::student resolves polymorphic student_id correctly:
# ABOUTME: a family-member student returns the FamilyMember, a user student the User.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::Attendance;
use Registry::DAO::Family;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Poly Attendance Org', slug => 'poly_attend',
});
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

my $teacher = Test::Registry::Fixtures::create_user($db, {
    username => 'poly_teacher', password => 'pw', user_type => 'staff',
});
my $parent = Test::Registry::Fixtures::create_user($db, {
    username => 'poly_parent', password => 'pw', user_type => 'parent',
});
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $teacher->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent->id);

$db = $db->schema($tenant->slug);

my $location = Test::Registry::Fixtures::create_location($db, { name => 'Poly School' });
my $project  = Test::Registry::Fixtures::create_project($db,  { name => 'Poly Program' });
my $event    = Test::Registry::Fixtures::create_event($db, {
    location_id => $location->id, project_id => $project->id,
    teacher_id  => $teacher->id, time => '2024-03-15 14:00:00', duration => 60,
});

# A child (family member) of the parent.
Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Poly Kid', birth_date => '2017-05-05', grade => '2',
});
my $child = Registry::DAO::FamilyMember->find($db, { child_name => 'Poly Kid' });
ok $child, 'created family member';

subtest 'family-member student resolves to the FamilyMember (not undef)' => sub {
    # Multi-child flow: student_id holds the family_member id AND family_member_id is set.
    my $att = Registry::DAO::Attendance->mark_attendance(
        $db, $event->id, $child->id, 'present', $teacher->id, undef, $child->id
    );
    my $student = $att->student($db);
    ok $student, 'student() returns an object (was undef before the fix)';
    isa_ok $student, 'Registry::DAO::FamilyMember', 'student is a FamilyMember';
    is $student->child_name, 'Poly Kid', 'correct child resolved';
};

subtest 'user student (no family_member_id) still resolves to the User' => sub {
    my $att = Registry::DAO::Attendance->mark_attendance(
        $db, $event->id, $teacher->id, 'present', $teacher->id
    );
    my $student = $att->student($db);
    ok $student, 'student() returns an object';
    isa_ok $student, 'Registry::DAO::User', 'student is a User when no family_member_id';
};

done_testing;
