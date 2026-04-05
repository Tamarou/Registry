#!/usr/bin/env perl
# ABOUTME: Playwright test helper that seeds admin dashboard test data.
# ABOUTME: Creates admin user with magic link, location, program, session, enrollment.

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
use Registry::DAO::PricingPlan;
use Registry::DAO::Family;
use Registry::DAO::FamilyMember;
use JSON::PP qw(encode_json);

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

my $ts = time();

# Admin user
my $admin = Registry::DAO::User->create($db, {
    username  => "admin_pw_$ts",
    email     => "admin_pw_${ts}\@test.com",
    name      => 'Admin User',
    user_type => 'admin',
});

my (undef, $token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $admin->id,
    purpose    => 'login',
    expires_in => 24,
});

# Location, program, session, event
my $loc = Registry::DAO::Location->create($db, {
    name         => 'Admin Studio',
    slug         => "admin-studio-$ts",
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $prog = Registry::DAO::Project->create($db, {
    name              => 'Admin Camp',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $sess = Registry::DAO::Session->create($db, {
    name       => 'Admin Week 1',
    start_date => '2026-06-01',
    end_date   => '2026-06-05',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $evt = Registry::DAO::Event->create($db, {
    time        => '2026-06-01 09:00:00',
    duration    => 420,
    location_id => $loc->id,
    project_id  => $prog->id,
    teacher_id  => $admin->id,
    capacity    => 16,
    metadata    => {},
});

$sess->add_events($db, $evt->id);

Registry::DAO::PricingPlan->create($db, {
    session_id => $sess->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 300.00,
});

# Parent with enrollment
my $parent = Registry::DAO::User->create($db, {
    username  => "dash_parent_$ts",
    name      => 'Dashboard Parent',
    user_type => 'parent',
    email     => "dash_parent_${ts}\@test.com",
});

my $child = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name        => 'Dashboard Kid',
    birth_date        => '2018-01-01',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'P', phone => '555' },
});

$db->insert('enrollments', {
    session_id       => $sess->id,
    student_id       => $parent->id,
    family_member_id => $child->id,
    status           => 'active',
});

print encode_json({
    token    => $token,
    admin_id => $admin->id,
});
print "\n";
