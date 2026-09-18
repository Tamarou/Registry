#!/usr/bin/env perl
# ABOUTME: Proves get_active_for_parent returns the program and location names the
# ABOUTME: parent dashboard renders, without inflating the per-session event counts.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::Attendance;
use Registry::DAO::Enrollment;
use Registry::DAO::Family;
use Registry::DAO::FamilyMember;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Dashboard Details Org', slug => 'dash_details',
});
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

my $teacher = Test::Registry::Fixtures::create_user($db, {
    username => 'dash_teacher', password => 'pw', user_type => 'staff',
});
my $parent = Test::Registry::Fixtures::create_user($db, {
    username => 'dash_parent', password => 'pw', user_type => 'parent',
});
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $teacher->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent->id);

$db = $db->schema($tenant->slug);

my $location = Test::Registry::Fixtures::create_location($db, { name => 'Maple Street School' });
my $project  = Test::Registry::Fixtures::create_project($db,  { name => 'Creative Coding' });

# The session carries no project_id/location_id metadata, so the program and
# location have to be resolved through its events -- the shape the dashboard hits.
my $session = Test::Registry::Fixtures::create_session($db, {
    name       => 'Summer 2025 Coding',
    start_date => '2025-06-01',
    end_date   => '2025-08-15',
    status     => 'published',
});

# Three events, so a join that multiplies rows would show total_events > 3.
my @events = map {
    Test::Registry::Fixtures::create_event($db, {
        location_id => $location->id,
        project_id  => $project->id,
        teacher_id  => $teacher->id,
        time        => "2025-06-0$_ 14:00:00",
        duration    => 60,
    })
} 1 .. 3;
$session->add_events($db, map { $_->id } @events);

Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Liam Parent', birth_date => '2016-04-10', grade => '3',
});
my $child = Registry::DAO::FamilyMember->find($db, { child_name => 'Liam Parent' });
ok $child, 'child created for the parent';

Registry::DAO::Enrollment->create($db->db, {
    session_id       => $session->id,
    family_member_id => $child->id,
    student_type     => 'family_member',
    parent_id        => $parent->id,
    status           => 'active',
});

# Present at exactly one of the three events.
Registry::DAO::Attendance->mark_attendance(
    $db, $events[0]->id, $child->id, 'present', $teacher->id, undef, $child->id
);

my $rows = Registry::DAO::Enrollment->get_active_for_parent($db, $parent->id);
is scalar @$rows, 1, 'one active enrollment for the parent';

my $row = $rows->[0];
is $row->{program_name},    'Creative Coding',     'program_name comes back from the query';
is $row->{location_name},   'Maple Street School', 'location_name comes back from the query';
is $row->{total_events},    3, 'total_events not inflated by the program/location joins';
is $row->{attended_events}, 1, 'attended_events not inflated either';

done_testing;
