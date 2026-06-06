#!/usr/bin/env perl
# ABOUTME: Playwright test helper that seeds shared lifecycle test prerequisites.
# ABOUTME: Creates Morgan (admin), Nancy (parent), Amara (teacher), tenant, location, program type.

use strict;
use warnings;
use 5.34.0;
use experimental 'signatures';

use lib qw(lib t/lib);

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::Location;
use Registry::DAO::ProgramType;
use Registry::DAO::MagicLinkToken;
use JSON::PP qw(encode_json);

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

# Unique per invocation to prevent collisions across repeated runs
my $ts = time() . '_' . $$;

# ---------------------------------------------------------------------------
# Tenant
# ---------------------------------------------------------------------------
my $tenant_slug = "lifecycle_$ts";
my $tenant = Registry::DAO::Tenant->create($db, {
    name => "Lifecycle Test $ts",
    slug => $tenant_slug,
});

# ---------------------------------------------------------------------------
# Morgan: admin/manager user (the focus of this leg)
# ---------------------------------------------------------------------------
my $morgan = Registry::DAO::User->create($db, {
    username  => "morgan_lc_$ts",
    email     => "morgan_lc_${ts}\@test.com",
    name      => 'Morgan Manager',
    user_type => 'admin',
});

$db->insert('tenant_users', {
    tenant_id  => $tenant->id,
    user_id    => $morgan->id,
    is_primary => 1,
});

my (undef, $morgan_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $morgan->id,
    purpose    => 'login',
    expires_in => 24,
});

# ---------------------------------------------------------------------------
# Nancy: parent user (seeded now for later legs)
# ---------------------------------------------------------------------------
my $nancy = Registry::DAO::User->create($db, {
    username  => "nancy_lc_$ts",
    email     => "nancy_lc_${ts}\@test.com",
    name      => 'Nancy Parent',
    user_type => 'parent',
});

$db->insert('tenant_users', {
    tenant_id  => $tenant->id,
    user_id    => $nancy->id,
    is_primary => 0,
});

my (undef, $nancy_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $nancy->id,
    purpose    => 'login',
    expires_in => 24,
});

# ---------------------------------------------------------------------------
# Amara: teacher/staff user (seeded now for later legs)
# ---------------------------------------------------------------------------
my $amara = Registry::DAO::User->create($db, {
    username  => "amara_lc_$ts",
    email     => "amara_lc_${ts}\@test.com",
    name      => 'Amara Teacher',
    user_type => 'staff',
});

$db->insert('tenant_users', {
    tenant_id  => $tenant->id,
    user_id    => $amara->id,
    is_primary => 0,
});

my (undef, $amara_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $amara->id,
    purpose    => 'login',
    expires_in => 24,
});

# ---------------------------------------------------------------------------
# Program type: use the existing 'afterschool' type (seeded by sqitch)
# ---------------------------------------------------------------------------
my $program_type = Registry::DAO::ProgramType->find_by_slug($db, 'afterschool');
die "afterschool program type not found; run sqitch deploy + workflow import first\n"
    unless $program_type;

# ---------------------------------------------------------------------------
# Location for program assignment
# ---------------------------------------------------------------------------
my $location = Registry::DAO::Location->create($db, {
    name         => "Lifecycle Studio $ts",
    slug         => "lifecycle-studio-$ts",
    address_info => {
        street  => '123 Art Lane',
        city    => 'Orlando',
        state   => 'FL',
        zip     => '32801',
    },
    metadata => {},
});

# ---------------------------------------------------------------------------
# Output JSON
# ---------------------------------------------------------------------------
print encode_json({
    ts          => $ts,
    tenant_slug => $tenant_slug,
    tenant_id   => $tenant->id,
    location_id => $location->id,
    program_type_slug => $program_type->slug,
    morgan => {
        user_id => $morgan->id,
        token   => $morgan_token,
        email   => "morgan_lc_${ts}\@test.com",
    },
    nancy => {
        user_id => $nancy->id,
        token   => $nancy_token,
        email   => "nancy_lc_${ts}\@test.com",
    },
    amara => {
        user_id => $amara->id,
        token   => $amara_token,
        email   => "amara_lc_${ts}\@test.com",
    },
});
print "\n";
