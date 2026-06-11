#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: the signup funnel produces a working,
# ABOUTME: billable tenant.  Stage 1 walks the full funnel over HTTP with realistic data.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use utf8;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing diag is like ok subtest BAIL_OUT )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows seed_platform_pricing_relationship);

use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;

# ---------------------------------------------------------------------------
# Database setup
# ---------------------------------------------------------------------------
my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;    # registry-schema DAO
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

# ---------------------------------------------------------------------------
# Import all non-draft workflows into the registry schema.
# Tenant->provision copies every registry workflow (except tenant-signup) into
# the tenant schema via copy_workflow.  If only tenant-signup is imported here,
# the tenant schema ends up with zero workflows — making the Stage 2 workflow
# count assertion vacuous.  import_all_workflows also seeds outcome definitions
# before the workflow rows, satisfying the outcome_definition_id FK.
# ---------------------------------------------------------------------------
import_all_workflows($dao);

my ($signup_wf) = $dao->find(Workflow => { slug => 'tenant-signup' });
ok $signup_wf, 'tenant-signup workflow present in registry schema'
    or BAIL_OUT('tenant-signup workflow missing -- cannot walk funnel');

# Fixture: seed the platform pricing relationship -- see #268 for full rationale.
my $plan_id = seed_platform_pricing_relationship($dao)
    or BAIL_OUT('seed_platform_pricing_relationship failed -- cannot walk pricing step');

# ---------------------------------------------------------------------------
# App setup: pin the app dao to the registry-context DAO so the workflow
# controller resolves the tenant-signup workflow correctly.  (Matches the
# data-flow test's $t->app->helper(dao => sub { $db }) pattern.)
# ---------------------------------------------------------------------------
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ---------------------------------------------------------------------------
# Walk the tenant-signup funnel with REALISTIC data (Portland-Art-Collective-
# style from t/controller/tenant-signup-data-flow.t), through the full path:
#   landing -> profile -> users -> pricing -> review -> payment -> complete
#
# Stage 1 asserts HTTP-level health only: each POST 302s to the expected next
# step, each GET 200s, and the complete page renders.
#
# Friction inventory (inputs to per-field discussion in issue #270):
#   landing     — no fields; POST with empty body advances.  Required: none.
#   profile     — 'name' consumed downstream by _provision_tenant (falls back
#                 to 'Organization' without it); 'description' is accepted
#                 empty but displayed on review; 'billing_email' displayed on
#                 review if non-empty.  Realistic data tests all three.
#   users       — 'admin_name', 'admin_email', 'admin_username' accumulated in
#                 run data and rendered on review; 'admin_user_type' must be
#                 'admin' to avoid the invite-pending warn() path in
#                 _provision_tenant (pristine-output hazard noted in spec).
#                 Team kept admin-only here to preserve pristine output.
#   pricing     — 'selected_plan_id' required (must be a valid UUID for an
#                 active platform relationship; absent silently skips).  The
#                 seeded plan renders and is selected explicitly.
#   review      — 'terms_accepted' required by the controller (Workflows.pm)
#                 BEFORE calling step->process; the step itself accepts empty
#                 body but the controller gate refuses without it.
#   payment     — 'collect_payment_method' + 'setup_intent_id' (seti_test...)
#                 trigger the test-mode provision path in TenantPayment.pm:43-46.
#                 The seti_test branch wins on dispatch order before the no-keys
#                 branch, so Stripe env keys are irrelevant to this POST.
# ---------------------------------------------------------------------------

# Realistic identity: Portland-Art-Collective-style, $$-suffixed for uniqueness.
my $org_name     = "Cascadia Maker Camp $$";
my $admin_name   = "Jordan Cascadia $$";
my $admin_email  = "jordan_$$\@cascadiamakers.example";
my $admin_user   = "jordan_$$";
my $billing_email = "billing_$$\@cascadiamakers.example";
my $description  = 'Maker education for youth and adults in the Pacific Northwest';

# -- Step: landing (starts the run) ----------------------------------------
# POST to the tenant-signup start URL.  No form fields required.
# Expected: 302 -> /tenant-signup/<run-id>/profile
$t->post_ok('/tenant-signup')
  ->status_is(302)
  ->header_like(Location => qr{/tenant-signup/[^/]+/profile$},
                'landing POST redirects to profile step');

my $profile_url = $t->tx->res->headers->location;

# GET before POST (establishes session / populates CSRF token if any).
$t->get_ok($profile_url)->status_is(200);

# -- Step: profile ----------------------------------------------------------
# Realistic org profile data.  'name' is the only field _provision_tenant
# reads from this step; 'description' and 'billing_email' are captured in run
# data and displayed on the review page (content_like assertions below).
# Expected: 302 -> /tenant-signup/<run-id>/users
$t->post_ok($profile_url => form => {
    name          => $org_name,
    description   => $description,
    billing_email => $billing_email,
})->status_is(302)
  ->header_like(Location => qr{/tenant-signup/[^/]+/users$},
                'profile POST redirects to users step');

my $users_url = $t->tx->res->headers->location;

# GET before POST.
$t->get_ok($users_url)->status_is(200);

# -- Step: users ------------------------------------------------------------
# Realistic admin-only team.  'admin_user_type => admin' avoids the
# invite-pending warn() path in _provision_tenant (pristine output).
# Full fields (admin_name/email/username) are rendered on the review page.
# Expected: 302 -> /tenant-signup/<run-id>/pricing
$t->post_ok($users_url => form => {
    admin_name      => $admin_name,
    admin_email     => $admin_email,
    admin_username  => $admin_user,
    admin_user_type => 'admin',
})->status_is(302)
  ->header_like(Location => qr{/tenant-signup/[^/]+/pricing$},
                'users POST redirects to pricing step');

my $pricing_url = $t->tx->res->headers->location;

# -- Step: pricing (GET) -- assert seeded plan renders ---------------------
# This GET doubles as the #268 guard: if the seeded relationship is absent,
# prepare_pricing_data returns an empty list, the template renders no radio
# buttons, and the assertion below catches that silently-broken path.
my $pricing_page = $t->get_ok($pricing_url)->status_is(200)->tx->res->body;

like $pricing_page, qr/selected_plan_id/,
    'pricing page renders at least one plan radio (seeded relationship visible, #268 guard)';
like $pricing_page, qr/Registry Revenue Share/,
    'pricing page shows the seeded revenue-share plan name';

# -- Step: pricing (POST) -- select the seeded plan -----------------------
# 'selected_plan_id' is consumed via exists $form_data->{selected_plan_id}
# in PricingPlanSelection::process.
# Expected: 302 -> /tenant-signup/<run-id>/review
$t->post_ok($pricing_url => form => {
    selected_plan_id => $plan_id,
})->status_is(302)
  ->header_like(Location => qr{/tenant-signup/[^/]+/review$},
                'pricing POST redirects to review step');

my $review_url = $t->tx->res->headers->location;

# -- Step: review (GET) -- verify accumulated data renders ----------------
# The TenantSignupReview step spreads profile/team into the stash.
# The template reads stash('profile') and stash('team') directly.
# Assert that all four realistic-data fields from the profile and users steps
# are displayed on the review page (cribbed from tenant-signup-data-flow.t).
$t->get_ok($review_url)
  ->status_is(200)
  ->content_like(qr/\Q$org_name\E/,
      'review page shows organization name from profile step')
  ->content_like(qr/\Q$billing_email\E/,
      'review page shows billing email from profile step')
  ->content_like(qr/\Q$admin_name\E/,
      'review page shows admin name from users step')
  ->content_like(qr/\Q$admin_email\E/,
      'review page shows admin email from users step')
  ->content_like(qr/\Q$admin_user\E/,
      'review page shows admin username from users step');

# -- Step: review (POST) -- accept terms ----------------------------------
# The controller validates terms_accepted before calling step->process.
# No other field is required at this step; all accumulation happened earlier.
# Expected: 302 -> /tenant-signup/<run-id>/payment
$t->post_ok($review_url => form => {
    terms_accepted => 1,
})->status_is(302)
  ->header_like(Location => qr{/tenant-signup/[^/]+/payment$},
                'review POST redirects to payment step');

my $payment_url = $t->tx->res->headers->location;

# -- Step: payment (GET) --------------------------------------------------
$t->get_ok($payment_url)->status_is(200);

# -- Step: payment (POST via seti_test seam) ------------------------------
# POST collect_payment_method=1 + setup_intent_id=seti_test_... dispatches
# to handle_setup_completion -> _provision_tenant (TenantPayment.pm:43-46,
# 283-294).  The seti_test branch wins on dispatch order before the no-keys
# branch, so Stripe env keys are irrelevant to this POST.
# Expected: 302 -> /tenant-signup/<run-id>/complete
$t->post_ok($payment_url => form => {
    collect_payment_method => 1,
    setup_intent_id        => 'seti_test_acquire_' . $$,
})->status_is(302)
  ->header_like(Location => qr{/tenant-signup/[^/]+/complete$},
                'payment POST redirects to complete step');

my $complete_url = $t->tx->res->headers->location;

# -- Step: complete -------------------------------------------------------
# The complete step (RegisterTenant) renders the success page.
$t->get_ok($complete_url)->status_is(200);

# ---------------------------------------------------------------------------
# Stage 2: working-tenant assertions.
#
# The funnel has completed.  Retrieve the run's accumulated data to find the
# provisioned slug and then assert that the tenant is fully functional from
# Alex's perspective: row exists, schema exists, workflows were cloned, the
# admin user is dual-resident, the storefront serves, and the billing fields
# are set correctly.
# ---------------------------------------------------------------------------

my $run      = $signup_wf->latest_run($db);
my $run_data = $run->data;

# The slug is written into run data as 'subdomain' by _provision_tenant.
# It is derived from the org name: lc(name =~ s/\s+/_/gr) with hyphens also
# replaced by underscores (see Tenant::provision, TenantPayment::_provision_tenant).
my $slug = $run_data->{subdomain};
ok $slug, "provisioned tenant slug present in run data (${\($slug // 'undef')})";

# ---------------------------------------------------------------------------
# Assertion 1: tenant row + schema exist; clone artifacts present.
# ---------------------------------------------------------------------------
subtest 'tenant row, schema, and workflows exist' => sub {
    # 1a. Tenant row in registry.tenants
    my $tenant_row = $db->query(
        q{SELECT id, slug, name FROM registry.tenants WHERE slug = ?},
        $slug
    )->hash;
    ok $tenant_row, "tenant row found in registry.tenants for slug '$slug'";

    # 1b. Postgres schema exists.
    # information_schema.schemata is available on any PostgreSQL connection and
    # does not require special privileges.
    my $schema_row = $db->query(
        q{SELECT 1 FROM information_schema.schemata WHERE schema_name = ?},
        $slug
    )->hash;
    ok $schema_row, "postgres schema '$slug' exists (clone_schema ran)";

    # 1c. Workflows were copied into the tenant schema.
    # provision copies every registry workflow except tenant-signup; at least
    # one workflow (e.g. tenant-storefront) should always be present.
    # Use a format-safe qualified identifier: the slug was already normalised
    # to a safe postgres identifier (lc + spaces/hyphens -> underscores) by
    # Tenant::provision, so direct interpolation is safe here.
    my $wf_count = $db->query(
        "SELECT count(*) AS n FROM ${\ $db->dbh->quote_identifier($slug) }.workflows"
    )->hash->{n};
    ok $wf_count > 0,
        "tenant schema '$slug' has $wf_count workflow(s) (copy_workflow ran)";
};

# ---------------------------------------------------------------------------
# Assertion 2: signup user is dual-resident (same id in registry.users and
# <slug>.users).
# ---------------------------------------------------------------------------
subtest 'admin user is dual-resident in registry and tenant schemas' => sub {
    # The admin user was created/looked up by _provision_tenant using the
    # admin_username field from the funnel.
    my $registry_user = $db->query(
        q{SELECT id FROM registry.users WHERE username = ?},
        $admin_user
    )->hash;
    ok $registry_user, "admin user '$admin_user' exists in registry.users"
        or return;    # guard: later assertions would warn on undef $user_id

    my $user_id = $registry_user->{id};

    my $tenant_user = $db->query(
        "SELECT id FROM ${\ $db->dbh->quote_identifier($slug) }.users WHERE id = ?",
        $user_id
    )->hash;
    ok $tenant_user, "admin user id ${user_id} also exists in ${slug}.users (dual-resident)";
    is $tenant_user->{id}, $user_id,
        'registry.users.id matches tenant.users.id (same identity, no copy)';
};

# ---------------------------------------------------------------------------
# Assertion 3: tenant's storefront serves.
# GET / with Host: <slug>.localhost must return 200 and contain the org name.
#
# A fresh Test::Mojo->new('Registry') boots a new app instance whose dao helper
# is NOT overridden, so host-based tenant resolution takes effect.  $ENV{DB_URL}
# is already set to the test DB, so the new app resolves to the correct DB.
# The existing $t pins its dao to the registry schema (needed for the signup
# workflow walk) and is NOT reused here.
# ---------------------------------------------------------------------------
subtest 'tenant storefront serves at <slug>.localhost' => sub {
    use Test::Mojo;
    my $t2 = Test::Mojo->new('Registry');

    my $res = $t2->get_ok('/' => { Host => "$slug.localhost" })
      ->status_is(200, 'storefront GET / returns 200')
      ->tx->res;

    # Pin to the elements ProgramListing populates (page_title -> stash).
    # The <title> tag and the landing-logo nav div both render stash('page_title'),
    # which ProgramListing sets to the tenant name.  Asserting here (rather than
    # page-wide) confirms the fix to that step is what surfaces the org name.
    my $dom = $res->dom;

    my $title_text = $dom->at('title') ? $dom->at('title')->text : '';
    like $title_text, qr/\Q$org_name\E/i,
        'storefront <title> contains the organization name';

    my $logo_el = $dom->at('.landing-logo');
    ok $logo_el, 'storefront page has a .landing-logo element';
    like( ($logo_el ? $logo_el->text : ''), qr/\Q$org_name\E/i,
        'landing-logo element contains the organization name' )
        if $logo_el;
};

# ---------------------------------------------------------------------------
# Assertion 4: billing fields are set correctly for the seti_test path.
# _provision_tenant writes billing_status='trial' and stripe_subscription_id
# = 'sub_test_...' when subscription data carries a stripe_subscription_id
# (set by handle_setup_completion on the seti_test branch).
# ---------------------------------------------------------------------------
subtest 'tenant row carries billing fields from seti_test path' => sub {
    my $tenant_row = $db->query(
        q{SELECT billing_status, stripe_subscription_id
          FROM registry.tenants WHERE slug = ?},
        $slug
    )->hash;
    ok $tenant_row, 'tenant row accessible for billing assertions';

    is $tenant_row->{billing_status}, 'trial',
        'billing_status is "trial" on the seti_test provision path';

    like $tenant_row->{stripe_subscription_id}, qr/^sub_test_/,
        'stripe_subscription_id starts with sub_test_ (seti_test seam)';
};

$test_db->cleanup_test_database;
