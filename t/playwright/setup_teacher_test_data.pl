#!/usr/bin/env perl
# ABOUTME: Playwright test helper that seeds teacher attendance test data.
# ABOUTME: Creates teacher user with magic link, location, program, session, enrolled students.

use strict;
use warnings;
use 5.34.0;
use experimental 'signatures';

use lib qw(lib t/lib);

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::Family;
use JSON::PP qw(encode_json);
use DateTime;

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

my $ts = time();

# Teacher user
my $teacher = Registry::DAO::User->create($db, {
    username  => "amara_pw_$ts",
    email     => "amara_pw_${ts}\@test.com",
    name      => 'Amara Chen',
    user_type => 'staff',
});

my (undef, $teacher_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $teacher->id,
    purpose    => 'login',
    expires_in => 24,
});

# Location, program, session with today's event
my $loc = Registry::DAO::Location->create($db, {
    name         => 'Art Studio',
    slug         => "art-studio-$ts",
    address_info => { street => '200 Creative Way', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $prog = Registry::DAO::Project->create($db, {
    name              => 'Painting Basics',
    program_type_slug => 'afterschool',
    metadata          => {},
});

my $today = DateTime->now->ymd;
my $sess = Registry::DAO::Session->create($db, {
    name       => "Today's Painting Class",
    start_date => $today,
    end_date   => $today,
    status     => 'published',
    capacity   => 12,
    metadata   => {},
});

my $now_time = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
my $evt = Registry::DAO::Event->create($db, {
    time        => $now_time,
    duration    => 120,
    location_id => $loc->id,
    project_id  => $prog->id,
    teacher_id  => $teacher->id,
    capacity    => 12,
    metadata    => {},
});
$sess->add_events($db, $evt->id);

# Enroll students
my $parent = Registry::DAO::User->create($db, {
    username  => "att_parent_$ts",
    name      => 'Test Parent',
    user_type => 'parent',
    email     => "att_parent_${ts}\@test.com",
});

my @student_names = ('Student Alpha', 'Student Beta', 'Student Gamma');
my @student_ids;
for my $name (@student_names) {
    my $child = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name        => $name,
        birth_date        => '2017-01-01',
        grade             => '3',
        medical_info      => {},
        emergency_contact => { name => 'Test Parent', phone => '555-0000' },
    });
    push @student_ids, $child->id;

    $db->insert('enrollments', {
        session_id       => $sess->id,
        student_id       => $parent->id,
        family_member_id => $child->id,
        parent_id        => $parent->id,
        status           => 'active',
        metadata         => '{}',
    });
}

print encode_json({
    teacher_token => $teacher_token,
    teacher_id    => $teacher->id,
    event_id      => $evt->id,
    session_id    => $sess->id,
    student_ids   => \@student_ids,
});
print "\n";
