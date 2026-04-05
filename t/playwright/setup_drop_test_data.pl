#!/usr/bin/env perl
# ABOUTME: Playwright test helper that seeds drop/transfer test data.
# ABOUTME: Creates parent with enrollment, admin user, and magic link tokens.

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
use Registry::DAO::Enrollment;
use Registry::DAO::DropRequest;
use JSON::PP qw(encode_json);

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

my $ts = time();

# Location and program
my $loc = Registry::DAO::Location->create($db, {
    name         => 'Drop Test Studio',
    slug         => "drop-studio-$ts",
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $prog = Registry::DAO::Project->create($db, {
    name              => 'Drop Test Camp',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $teacher = Registry::DAO::User->create($db, {
    username  => "drop_teacher_$ts",
    email     => "drop_teacher_${ts}\@test.com",
    name      => 'Drop Teacher',
    user_type => 'staff',
});

my $sess = Registry::DAO::Session->create($db, {
    name       => 'Drop Test Week 1',
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
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});

$sess->add_events($db, $evt->id);

# Target session for transfer tests
my $target_sess = Registry::DAO::Session->create($db, {
    name       => 'Drop Test Week 2',
    start_date => '2026-06-08',
    end_date   => '2026-06-12',
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $target_evt = Registry::DAO::Event->create($db, {
    time        => '2026-06-08 09:00:00',
    duration    => 420,
    location_id => $loc->id,
    project_id  => $prog->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});

$target_sess->add_events($db, $target_evt->id);

# Parent with enrollment
my $parent = Registry::DAO::User->create($db, {
    username  => "drop_parent_$ts",
    email     => "drop_parent_${ts}\@test.com",
    name      => 'Drop Test Parent',
    user_type => 'parent',
});

my $child = Registry::DAO::FamilyMember->create($db, {
    family_id    => $parent->id,
    child_name   => 'Drop Test Kid',
    birth_date   => '2018-01-01',
    grade        => '3',
    medical_info => {},
});

my $enrollment = Registry::DAO::Enrollment->create($db, {
    session_id       => $sess->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'active',
});

# Admin user
my $admin = Registry::DAO::User->create($db, {
    username  => "drop_admin_$ts",
    email     => "drop_admin_${ts}\@test.com",
    name      => 'Drop Admin',
    user_type => 'admin',
});

# Magic link tokens
my (undef, $parent_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $parent->id,
    purpose    => 'login',
    expires_in => 24,
});

my (undef, $admin_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $admin->id,
    purpose    => 'login',
    expires_in => 24,
});

# Create a pending drop request for admin tests
my $drop_request = Registry::DAO::DropRequest->create($db, {
    enrollment_id    => $enrollment->id,
    requested_by     => $parent->id,
    reason           => 'Schedule conflict',
    refund_requested => 1,
    status           => 'pending',
});

print encode_json({
    parent_token     => $parent_token,
    admin_token      => $admin_token,
    enrollment_id    => $enrollment->id,
    drop_request_id  => $drop_request->id,
    target_session_id => $target_sess->id,
});
print "\n";
