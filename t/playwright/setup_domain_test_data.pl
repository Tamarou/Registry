#!/usr/bin/env perl
# ABOUTME: Playwright test helper that seeds a tenant and users for domain management tests.
# ABOUTME: Accepts DB_URL env var and a role argument; outputs JSON with token and user info.

use strict;
use warnings;
use 5.34.0;
use experimental 'signatures';

use lib qw(lib t/lib);

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::MagicLinkToken;
use JSON::PP qw(encode_json);

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------
my $role = $ARGV[0] // 'admin';   # 'admin' | 'staff'
die "Usage: $0 <admin|staff>\n"
    unless $role eq 'admin' || $role eq 'staff';

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

# ---------------------------------------------------------------------------
# Tenant: test_domain_tenant
# ---------------------------------------------------------------------------
my $tenant_slug = 'test_domain_tenant';
my $tenant = Registry::DAO::Tenant->find($db, { slug => $tenant_slug });
unless ($tenant) {
    $tenant = Registry::DAO::Tenant->create($db, {
        name => 'Test Domain Tenant',
        slug => $tenant_slug,
    });
}

# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------
my $ts = time();

# Admin user — always created so the spec can switch between roles
my $admin_email    = "domain_admin_${ts}\@example.com";
my $admin_username = "domain_admin_${ts}";

my $admin_user = Registry::DAO::User->find($db, { email => $admin_email });
unless ($admin_user) {
    $admin_user = Registry::DAO::User->create($db, {
        username  => $admin_username,
        email     => $admin_email,
        name      => 'Domain Admin User',
        user_type => 'admin',
    });
}

# Ensure tenant association for admin
my $existing_admin_link = $db->select('tenant_users', '*', {
    tenant_id => $tenant->id,
    user_id   => $admin_user->id,
})->hash;
unless ($existing_admin_link) {
    $db->insert('tenant_users', {
        tenant_id  => $tenant->id,
        user_id    => $admin_user->id,
        is_primary => 1,
    });
}

# Staff user
my $staff_email    = "domain_staff_${ts}\@example.com";
my $staff_username = "domain_staff_${ts}";

my $staff_user = Registry::DAO::User->find($db, { email => $staff_email });
unless ($staff_user) {
    $staff_user = Registry::DAO::User->create($db, {
        username  => $staff_username,
        email     => $staff_email,
        name      => 'Domain Staff User',
        user_type => 'staff',
    });
}

my $existing_staff_link = $db->select('tenant_users', '*', {
    tenant_id => $tenant->id,
    user_id   => $staff_user->id,
})->hash;
unless ($existing_staff_link) {
    $db->insert('tenant_users', {
        tenant_id  => $tenant->id,
        user_id    => $staff_user->id,
        is_primary => 0,
    });
}

# ---------------------------------------------------------------------------
# Magic link token for the requested role
# ---------------------------------------------------------------------------
my $target_user = $role eq 'admin' ? $admin_user : $staff_user;

my (undef, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $target_user->id,
    purpose    => 'login',
    expires_in => 24,
});

# ---------------------------------------------------------------------------
# Output JSON
# ---------------------------------------------------------------------------
print encode_json({
    token        => $plaintext,
    role         => $role,
    tenant_slug  => $tenant_slug,
    tenant_id    => $tenant->id,
    admin => {
        user_id  => $admin_user->id,
        email    => $admin_email,
        username => $admin_username,
    },
    staff => {
        user_id  => $staff_user->id,
        email    => $staff_email,
        username => $staff_username,
    },
});
print "\n";
