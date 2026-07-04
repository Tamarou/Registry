#!/usr/bin/env perl
# ABOUTME: Playwright test helper that seeds payment smoke-test data for a Connect-ready tenant.
# ABOUTME: Provisions tenant, paid session, parent/child, pre-seeded workflow run; outputs JSON.

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
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::PricingPlan;
use Registry::DAO::FamilyMember;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Test::Registry::StripeConnect;
use JSON::PP qw(encode_json);

my $db_url = $ENV{DB_URL}
    or die "DB_URL environment variable must be set\n";

# Guard: the spec only invokes this script when STRIPE_SECRET_KEY is a sk_test_ key.
# If it somehow runs without one, die clearly rather than touching live Stripe.
die "STRIPE_SECRET_KEY must be a sk_test_ key (live keys are forbidden in tests)\n"
    unless Test::Registry::StripeConnect::available();

# Obtain (or create) a charges_enabled Stripe Connect account.
# ready_account() polls until charges_enabled flips true (~48 s first call, cached thereafter).
my $connect_account_id = Test::Registry::StripeConnect::ready_account();

my $dao = Registry::DAO->new(url => $db_url);
my $db  = $dao->db;

# Unique suffix per invocation so repeated runs against the shared E2E database
# do not collide on unique constraints.
my $ts = time() . '_' . $$;

# ---------------------------------------------------------------------------
# Admin user (registry schema) -- required by Tenant->provision
# ---------------------------------------------------------------------------
my $admin = Registry::DAO::User->create($db, {
    username  => "pay_admin_$ts",
    email     => "pay_admin_${ts}\@example.com",
    name      => 'Payment Smoke Admin',
    user_type => 'admin',
});

# ---------------------------------------------------------------------------
# Provision a full tenant with its own schema.
# provision() clones the schema, copies program_types, workflows (including
# summer-camp-registration), outcome definitions, and the admin user.
# ---------------------------------------------------------------------------
my $slug = "pay_smoke_$ts";
my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "Payment Smoke Tenant $ts",
    slug  => $slug,
    users => [$admin],
});

# ---------------------------------------------------------------------------
# Mark the tenant Stripe Connect ready in registry.tenants
# ---------------------------------------------------------------------------
$db->query(
    'UPDATE registry.tenants'
    . ' SET stripe_connect_account_id = $1,'
    .     ' stripe_charges_enabled = TRUE,'
    .     ' stripe_details_submitted = TRUE'
    . ' WHERE slug = $2',
    $connect_account_id, $slug,
);

# Link the 2% percentage revenue-share plan (same SQL as tenant-paid-enrollment.t).
# A freshly provisioned tenant has platform_pricing_plan_id NULL, which resolves
# to the free 0% plan -- that would skip the Stripe charge entirely.
$db->query(q{
    UPDATE registry.tenants SET platform_pricing_plan_id = (
        SELECT id FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND pricing_model_type = 'percentage'
           AND metadata->>'default' IS DISTINCT FROM 'true'
         ORDER BY created_at
         LIMIT 1
    ) WHERE slug = ?
}, $slug);

# ---------------------------------------------------------------------------
# Tenant-scoped DAO for all data that lives in the tenant schema
# ---------------------------------------------------------------------------
my $tdao = Registry::DAO->new(url => $db_url, schema => $slug);
my $tdb  = $tdao->db;

# ---------------------------------------------------------------------------
# Location (tenant schema)
# ---------------------------------------------------------------------------
my $location = Registry::DAO::Location->create($tdb, {
    name         => "Payment Smoke Studio $ts",
    address_info => {
        street_address => '100 Payment Ave',
        city           => 'Orlando',
        state          => 'FL',
        postal_code    => '32801',
    },
    metadata => {},
});

# ---------------------------------------------------------------------------
# Program / Project (tenant schema)
# ---------------------------------------------------------------------------
my $program = Registry::DAO::Project->create($tdb, {
    name              => "Payment Smoke Camp $ts",
    slug              => "pay-smoke-camp-$ts",
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {
        age_range   => { min => 5, max => 11 },
        description => 'Smoke-test camp for payment E2E.',
    },
});

# ---------------------------------------------------------------------------
# Teacher (tenant schema)
# ---------------------------------------------------------------------------
my $teacher = Registry::DAO::User->create($tdb, {
    username  => "pay_teacher_$ts",
    email     => "pay_teacher_${ts}\@example.com",
    name      => 'Payment Teacher',
    user_type => 'staff',
});

# ---------------------------------------------------------------------------
# Paid session: $150 (tenant schema)
# ---------------------------------------------------------------------------
my $session = Registry::DAO::Session->create($tdb, {
    name       => "Payment Smoke Week ($ts)",
    start_date => '2027-07-07',
    end_date   => '2027-07-11',
    status     => 'published',
    capacity   => 10,
    metadata   => {
        program_id  => $program->id,
        location_id => $location->id,
    },
});

# One event so the session is fully formed
Registry::DAO::Event->create($tdb, {
    session_id  => $session->id,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    time        => '2027-07-07 09:00:00',
    duration    => 420,   # 7 hours (09:00-16:00)
    capacity    => 10,
    metadata    => {},
});

# Pricing plan: $150 standard
Registry::DAO::PricingPlan->create($tdb, {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 150.00,
});

# ---------------------------------------------------------------------------
# Parent user: created in registry schema so the magic-link lookup (which
# runs against the registry schema on /auth/magic/*) can find the token.
# copy_user() mirrors the row into the tenant schema so the tenant-scoped
# workflow steps (which use tdb) can find the user by the same UUID.
# ---------------------------------------------------------------------------
my $parent_email = "pay_parent_${ts}\@example.com";
my $parent = Registry::DAO::User->create($db, {
    username  => "pay_parent_$ts",
    email     => $parent_email,
    name      => 'Payment Parent',
    user_type => 'parent',
});

# Mirror parent into tenant schema (preserves UUID)
$db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $slug, $parent->id);

# Link parent to tenant so tenant_users record exists
$db->insert('tenant_users', {
    tenant_id  => $tenant->id,
    user_id    => $parent->id,
    is_primary => 0,
});

# ---------------------------------------------------------------------------
# Child (tenant schema) -- enrollments are created in the tenant schema
# ---------------------------------------------------------------------------
my $child = Registry::DAO::FamilyMember->create($tdb, {
    family_id         => $parent->id,
    child_name        => 'Smoke Child',
    birth_date        => '2018-04-01',
    grade             => '2',
    medical_info      => { allergies => [], medications => [], notes => '' },
    emergency_contact => {
        name         => 'Payment Parent',
        phone        => '407-555-0100',
        relationship => 'Mother',
    },
});

# ---------------------------------------------------------------------------
# Magic-link token in the registry schema so /auth/magic/:token finds it.
# ---------------------------------------------------------------------------
my (undef, $parent_token) = Registry::DAO::MagicLinkToken->generate($db, {
    user_id    => $parent->id,
    purpose    => 'login',
    expires_in => 24,
});

# ---------------------------------------------------------------------------
# Pre-seeded workflow run in the tenant schema.
# latest_step_id is set to session-selection so that next_step($db) returns
# the payment step -- allowing process_workflow_run_step to accept a POST
# to the payment step without "Wrong step expected" errors.
# ---------------------------------------------------------------------------
my ($workflow) = Registry::DAO::Workflow->find($tdb, { slug => 'summer-camp-registration' });
die "summer-camp-registration workflow not found in tenant schema $slug\n" unless $workflow;

my ($session_selection_step) = Registry::DAO::WorkflowStep->find($tdb, {
    workflow_id => $workflow->id,
    slug        => 'session-selection',
});
die "session-selection step not found in tenant schema $slug\n" unless $session_selection_step;

my $run = Registry::DAO::WorkflowRun->create($tdb, {
    workflow_id    => $workflow->id,
    latest_step_id => $session_selection_step->id,
});

$run->update_data($tdb, {
    user_id            => $parent->id,
    children           => [ {
        id         => $child->id,
        first_name => 'Smoke',
        last_name  => 'Child',
        birth_date => '2018-04-01',
        grade      => '2',
    } ],
    session_selections => { $child->id => $session->id },
    enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
    __tenant_slug      => $slug,
});

# ---------------------------------------------------------------------------
# Output JSON for the spec to consume
# ---------------------------------------------------------------------------
print encode_json({
    tenant_slug     => $slug,
    tenant_id       => $tenant->id,
    connect_account => $connect_account_id,
    run_id          => $run->id,
    session_id      => $session->id,
    child_id        => $child->id,
    parent          => {
        token   => $parent_token,
        user_id => $parent->id,
        email   => $parent_email,
    },
    expected_amount => '150.00',
});
print "\n";
