#!/usr/bin/env perl
# ABOUTME: Playwright test helper that seeds camp registration test data.
# ABOUTME: Creates tenant, location, program, sessions, events, users; outputs JSON.

use strict;
use warnings;
use 5.34.0;
use experimental 'signatures';

use lib qw(lib t/lib);

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::ProgramType;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::PricingPlan;
use Registry::DAO::FamilyMember;
use Registry::DAO::Enrollment;
use Registry::DAO::MagicLinkToken;
use JSON::PP qw(encode_json);
use DateTime;

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

my $ts = time();

# ---------------------------------------------------------------------------
# Tenant
# ---------------------------------------------------------------------------
my $tenant_slug = 'super-awesome-cool-pottery';
my $tenant = Registry::DAO::Tenant->find($db, { slug => $tenant_slug });
unless ($tenant) {
    $tenant = Registry::DAO::Tenant->create($db, {
        name => 'Super Awesome Cool Pottery',
        slug => $tenant_slug,
    });
}

# ---------------------------------------------------------------------------
# Location
# ---------------------------------------------------------------------------
my $location = $dao->create( Location => {
    name => 'Super Awesome Cool Pottery Studio',
    slug => "sacp-studio-$ts",
    address_info => {
        street_address => '930 Hoffner Ave',
        city           => 'Orlando',
        state          => 'FL',
        postal_code    => '32809',
    },
    metadata => {
        facilities => { kiln => 1, wheel_stations => 16 },
    },
});

# ---------------------------------------------------------------------------
# Program type (use existing summer-camp seed)
# ---------------------------------------------------------------------------
my $program_type = Registry::DAO::ProgramType->find_by_slug($db, 'summer-camp');
die "summer-camp program type not found; run sqitch deploy first\n" unless $program_type;

# ---------------------------------------------------------------------------
# Program (Project)
# ---------------------------------------------------------------------------
my $program = $dao->create( Project => {
    name  => "Potter's Wheel Art Camp - Summer 2026",
    notes => 'FULL Day Camp | M-F | 9am-4pm | Grades K to 5',
    program_type_slug => 'summer-camp',
    metadata => {
        age_range        => { min => 5, max => 11 },
        grade_range      => 'K-5',
        description      => 'Step up to the awesome experience of making pottery on the wheel!',
        requirements     => ['Students Must Wear Closed Toed Shoes at All Times'],
        what_to_bring    => ['Brown Bag Lunch', '2 Snacks', 'ReUsable Water Bottle'],
    },
});

# ---------------------------------------------------------------------------
# Teacher
# ---------------------------------------------------------------------------
my $teacher = $dao->create( User => {
    username  => "camp_teacher_$ts",
    email     => "camp_teacher_${ts}\@example.com",
    name      => 'Camp Instructor',
    user_type => 'staff',
});

# ---------------------------------------------------------------------------
# Sessions and Events
# ---------------------------------------------------------------------------
my @session_configs = (
    { key => 'week1', name => 'Week 1 - Jun 1-5',   start => '2026-06-01', end => '2026-06-05', capacity => 16 },
    { key => 'week2', name => 'Week 2 - Jun 8-12',  start => '2026-06-08', end => '2026-06-12', capacity => 16 },
    { key => 'week3_full', name => 'Week 3 - Jun 15-19', start => '2026-06-15', end => '2026-06-19', capacity => 2 },
);

my %sessions;
for my $cfg (@session_configs) {
    my $session = Registry::DAO::Session->create($db, {
        name       => $cfg->{name},
        start_date => $cfg->{start},
        end_date   => $cfg->{end},
        status     => 'published',
        capacity   => $cfg->{capacity},
        metadata   => {
            program_id => $program->id,
            location_id => $location->id,
        },
    });

    # Create 5 events (Mon-Fri) for each session
    my $start_dt = DateTime->new(
        year => 2026,
        month => substr($cfg->{start}, 5, 2),
        day   => substr($cfg->{start}, 8, 2),
    );

    for my $day_offset (0..4) {
        my $event_date = $start_dt->clone->add(days => $day_offset);
        my $start_time = $event_date->clone->set(hour => 9, minute => 0);
        my $end_time   = $event_date->clone->set(hour => 16, minute => 0);

        my $event = $dao->create( Event => {
            session_id  => $session->id,
            location_id => $location->id,
            project_id  => $program->id,
            teacher_id  => $teacher->id,
            start_time  => $start_time,
            end_time    => $end_time,
            capacity    => $cfg->{capacity},
        });
    }

    # Create pricing plan for this session
    Registry::DAO::PricingPlan->create($db, {
        session_id => $session->id,
        plan_name  => 'Standard',
        amount     => 300.00,
    });

    $sessions{$cfg->{key}} = {
        id   => $session->id,
        name => $cfg->{name},
    };
}

# ---------------------------------------------------------------------------
# Returning parent with existing child
# ---------------------------------------------------------------------------
my $parent_email = "nancy.returning_${ts}\@example.com";
my $returning_parent = $dao->create( User => {
    username  => "nancy_returning_$ts",
    email     => $parent_email,
    name      => 'Nancy Returning',
    user_type => 'parent',
});

# Link parent to tenant
$db->insert('tenant_users', {
    tenant_id  => $tenant->id,
    user_id    => $returning_parent->id,
    is_primary => 0,
});

my $child = Registry::DAO::FamilyMember->create($db, {
    family_id    => $returning_parent->id,
    child_name   => 'Emma Johnson',
    birth_date   => '2018-03-15',
    grade        => '3',
    medical_info => {
        allergies   => ['peanuts'],
        medications => [],
        notes       => '',
    },
    emergency_contact => {
        name         => 'Nancy Johnson',
        phone        => '407-555-0199',
        relationship => 'Mother',
    },
});

# Magic link for returning parent
my (undef, $parent_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $returning_parent->id,
    purpose    => 'login',
    expires_in => 24,
});

# ---------------------------------------------------------------------------
# Admin user
# ---------------------------------------------------------------------------
my $admin_email = "camp_admin_${ts}\@example.com";
my $admin_user = $dao->create( User => {
    username  => "camp_admin_$ts",
    email     => $admin_email,
    name      => 'Camp Admin',
    user_type => 'admin',
});

# Link admin to tenant
$db->insert('tenant_users', {
    tenant_id  => $tenant->id,
    user_id    => $admin_user->id,
    is_primary => 1,
});

my (undef, $admin_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $admin_user->id,
    purpose    => 'login',
    expires_in => 24,
});

# ---------------------------------------------------------------------------
# Fill week3_full to capacity with 2 enrollments
# ---------------------------------------------------------------------------
my $week3_id = $sessions{week3_full}{id};
for my $i (1..2) {
    my $filler_parent = $dao->create( User => {
        username  => "filler_parent_${i}_$ts",
        email     => "filler_parent_${i}_${ts}\@example.com",
        name      => "Filler Parent $i",
        user_type => 'parent',
    });

    my $filler_child = Registry::DAO::FamilyMember->create($db, {
        family_id  => $filler_parent->id,
        child_name => "Filler Child $i",
        birth_date => '2018-01-01',
        grade      => '3',
    });

    Registry::DAO::Enrollment->create($db, {
        session_id       => $week3_id,
        family_member_id => $filler_child->id,
        parent_id        => $filler_parent->id,
        status           => 'active',
    });
}

# ---------------------------------------------------------------------------
# Output JSON
# ---------------------------------------------------------------------------
print encode_json({
    tenant_slug => $tenant_slug,
    tenant_id   => $tenant->id,
    location_id => $location->id,
    program_id  => $program->id,
    sessions    => \%sessions,
    returning_parent => {
        token      => $parent_token,
        user_id    => $returning_parent->id,
        email      => $parent_email,
        child_id   => $child->id,
        child_name => 'Emma Johnson',
    },
    admin => {
        token   => $admin_token,
        user_id => $admin_user->id,
    },
});
print "\n";
