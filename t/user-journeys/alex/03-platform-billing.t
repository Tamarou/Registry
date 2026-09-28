#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: Registry bills the tenant for the
# ABOUTME: platform subscription established during signup.
#
# Asserts at the DAO and job layer on purpose. Alex has no screens -- no
# platform-owner route, template or nav exists -- so unlike the other personas
# there is no control here to press. That is a decision (perigrin, #395) rather
# than the gap the other journey suites had: the screens Alex would need are
# enumerated in #426, and this suite should be reshaped only when they exist.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
# The payment step provisions directly when no Stripe keys are configured.
# Ambient keys would send it to create_setup_intent and a live API call.
BEGIN { delete @ENV{qw(STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY)} }

use 5.42.0;
use utf8;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing diag is like ok subtest BAIL_OUT )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(platform_revenue_share_plan_id);

use Registry::DAO;
use Registry::PriceOps::RevenueShare;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;

# ---------------------------------------------------------------------------
# Non-goal: recurring usage-based billing.
# The _get_usage_data branch is deliberately non-functional pending redesign
# (issue #263).  This leg asserts that the subscription is *established* at
# signup time, not that monthly invoices flow afterwards.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Database setup
# ---------------------------------------------------------------------------
my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;    # registry-schema DAO
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

# ---------------------------------------------------------------------------
# Import the tenant-signup workflow into the registry schema.
# The app's dao helper is pinned below to use this same schema connection.
# ---------------------------------------------------------------------------
$dao->import_workflows(['workflows/tenant-signup.yml']);

my ($signup_wf) = $dao->find(Workflow => { slug => 'tenant-signup' });
ok $signup_wf, 'tenant-signup workflow present in registry schema';

# The migration seeds the platform pricing relationship; fetch the plan id to select. See #268.
my $plan_id = platform_revenue_share_plan_id($dao)
    or BAIL_OUT('platform_revenue_share_plan_id failed -- cannot walk pricing step');

# ---------------------------------------------------------------------------
# App setup: pin the app dao to the registry-context DAO so the workflow
# controller resolves the tenant-signup workflow correctly.  (Matches the
# data-flow test's $t->app->helper(dao => sub { $db }) pattern.)
# ---------------------------------------------------------------------------
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ---------------------------------------------------------------------------
# Walk the tenant-signup funnel with minimal data.
#
# Friction inventory (inputs to the per-field discussion in issue #270):
#   landing     — no fields required; POST with empty body advances.
#   profile     — 'name' consumed downstream by _provision_tenant (falls back
#                 to 'Organization' without it); 'description' and
#                 'billing_email' are accepted empty without error.
#   users       — 'admin_name', 'admin_email', 'admin_username' accepted empty
#                 by the step's process() (WorkflowStep base class stores
#                 whatever it receives); 'admin_user_type' must be 'admin' to
#                 avoid the invite-pending warning path in _provision_tenant.
#   review      — 'terms_accepted' required by the controller (Workflows.pm:337-
#                 358) BEFORE calling step->process; the step itself accepts
#                 empty body but the controller gate refuses without it. This
#                 POST also provisions: no plan is chosen and nothing is
#                 charged, so review is the commit point.
# ---------------------------------------------------------------------------

# -- Step: land (starts the run) -------------------------------------------
$t->post_ok('/tenant-signup')->status_is(302);
my $profile_url = $t->tx->res->headers->location;
like $profile_url, qr{/tenant-signup/[^/]+/profile}, 'redirected to profile step';

# GET before POST (session/CSRF).
$t->get_ok($profile_url)->status_is(200);

# -- Step: profile ---------------------------------------------------------
# 'name' is the only field _provision_tenant reads from this step (via
# $data->{name}).  'description' and 'billing_email' are accepted but not
# consumed by any downstream step.
$t->post_ok($profile_url => form => {
    name          => 'Billing Journey Org ' . $$,
    description   => '',          # accepted empty
    billing_email => '',          # accepted empty
})->status_is(302);

my $users_url = $t->tx->res->headers->location;
like $users_url, qr{/tenant-signup/[^/]+/users}, 'redirected to users step';

# GET before POST.
$t->get_ok($users_url)->status_is(200);

# -- Step: users -----------------------------------------------------------
# admin_user_type => 'admin' avoids the invite-pending warn() in
# _provision_tenant; admin_name/email/username accepted empty by the step.
$t->post_ok($users_url => form => {
    admin_name      => 'BJ Admin ' . $$,
    admin_email     => "bj_admin_$$\@test.example",
    admin_username  => "bj_admin_$$",
    admin_user_type => 'admin',
})->status_is(302);

my $review_url = $t->tx->res->headers->location;
like $review_url, qr{/tenant-signup/[^/]+/review}, 'redirected to review step';

# -- Step: review (GET) -- assert the plan reaches the customer -----------
# This GET doubles as the #268 guard: if the seeded relationship is absent the
# resolver finds no plan to put the tenant on, and the page says nothing about
# the rate -- the silently-broken path this assertion catches.
my $review_page = $t->get_ok($review_url)->status_is(200)->tx->res->body;

like $review_page, qr/Solo/,
    'review page names the tier the tenant is about to be put on';

# -- Capture the displayed rate for the rate-consistency assertion below ----
# The review page is now the only page that quotes a rate before the customer
# commits, so it is the one that has to agree with the charge. Read the number
# out of the sentence the customer reads.
#
# There is deliberately no fallback that reads the rate out of a plan NAME:
# that is how "Registry Revenue Share - 2%" survived a move to 2.5%, and the
# name is not a place the rate is allowed to live.
my ($displayed_rate_str) =
    $review_page =~ /(\d+(?:\.\d+)?)\s*%\s*of\s+the\s+payments/i;

# -- Step: review (POST) --------------------------------------------------
# The controller (Workflows.pm:337-358) validates terms_accepted and checks
# for accumulated admin_name/admin_email/name in run data before advancing.
# terms_accepted is the only field the user must explicitly submit here;
# all other required data must have been collected in earlier steps.
$t->post_ok($review_url => form => {
    terms_accepted => 1,    # required by controller review-step validation
})->status_is(302);

my $complete_url = $t->tx->res->headers->location;
like $complete_url, qr{/tenant-signup/[^/]+/complete}, 'redirected to complete step';

# -- Step: complete -------------------------------------------------------
$t->get_ok($complete_url)->status_is(200);

# ---------------------------------------------------------------------------
# Retrieve the workflow run and its accumulated data for assertion.
# ---------------------------------------------------------------------------
my $run = $signup_wf->latest_run($db);
ok $run, 'workflow run exists after funnel walk';

my $run_data = $run->data;

# ---------------------------------------------------------------------------
# Assertion 1a: nothing is stashed about a choice nobody was offered
# ---------------------------------------------------------------------------
subtest 'run data carries no plan selection' => sub {
    ok !$run_data->{selected_pricing_plan},
        'no selected_pricing_plan: the applicant was never asked';
};

# ---------------------------------------------------------------------------
# Assertion 1b: the provisioned tenant row carries billing fields
# ---------------------------------------------------------------------------
subtest 'provisioned tenant row carries billing fields' => sub {
    # _provision_tenant writes the tenant slug into run_data as 'subdomain'.
    my $slug = $run_data->{subdomain};
    ok $slug, "provisioned tenant slug present in run data ($slug)";

    my $tenant_row = $db->query(
        q{SELECT stripe_subscription_id, billing_status, trial_ends_at
          FROM registry.tenants WHERE slug = ?},
        $slug
    )->hash;
    ok $tenant_row, 'provisioned tenant row found in registry.tenants';

    is $tenant_row->{stripe_subscription_id}, undef,
        'no Stripe subscription: a $0 plan has nothing to subscribe to';
    is $tenant_row->{billing_status}, 'active',
        'billing_status is "active" -- the tenant is live, not on a clock';
    is $tenant_row->{trial_ends_at}, undef,
        'no trial end date, because there is no trial';
};

# ---------------------------------------------------------------------------
# Assertion 2: no tenant<->plan pricing_relationship exists post-signup.
#
# PricingPlanSelection only stashes the selected plan in run data; it does not
# INSERT a registry.pricing_relationships row linking the new tenant as
# provider or consumer.  _provision_tenant writes billing fields onto the
# tenant row but also does not create a pricing_relationship.
#
# With #267 landed, the tenant<->plan link is persisted as the
# tenants.platform_pricing_plan_id FK (Option A), NOT as a pricing_relationships
# row -- those tables are for plan selection/discovery, not the charge-time
# authority.  So two things must hold: (a) the persisted FK link equals the plan
# the tenant selected, and (b) no pricing_relationships row was created with the
# new tenant as provider or consumer (a spurious one would mean the rate could
# be read from the wrong place).
# ---------------------------------------------------------------------------
subtest '#267: tenant->plan link persisted on the tenant row' => sub {
    my $slug = $run_data->{subdomain};
    ok $slug, "tenant slug available ($slug)";

    # Look up the provisioned tenant's id.
    my $tenant_row = $db->query(
        q{SELECT id FROM registry.tenants WHERE slug = ?}, $slug
    )->hash;
    ok $tenant_row, 'provisioned tenant row found';

    my $tenant_id = $tenant_row->{id};

    # (a) The persisted FK link equals the plan the tenant selected at signup.
    my $link = $db->query(
        q{SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?}, $slug
    )->hash->{platform_pricing_plan_id};
    is $link, $plan_id,
        'tenants.platform_pricing_plan_id equals the plan on sale (#267 persisted link)';

    # (b) Assert zero pricing_relationships rows where the new tenant is either
    # provider or consumer -- those are the two roles a tenant could occupy in
    # a platform-billing relationship.  The only relationship in the table
    # should be the fixture we inserted above (provider = platform UUID).
    my $as_provider = $db->query(q{
        SELECT count(*) AS n FROM registry.pricing_relationships
        WHERE provider_id = ?
    }, $tenant_id)->hash->{n};

    my $as_consumer = $db->query(q{
        SELECT count(*) AS n FROM registry.pricing_relationships
        WHERE consumer_id = ?
    }, $tenant_id)->hash->{n};

    is $as_provider + 0, 0,
        'no pricing_relationships row with the new tenant as provider (#267 dependency)';
    is $as_consumer + 0, 0,
        'no pricing_relationships row with the new tenant as consumer (#267 dependency)';
};

# ---------------------------------------------------------------------------
# Assertion 3 (#267): rate-consistency -- displayed rate equals charged rate.
#
# The review page advertises a rate, rendered from the plan's own
# pricing_configuration.  The CHARGED rate is what the
# Stripe application fee is computed from: Registry::DAO::Payment::_connect_params
# derives it via Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant
# for the provisioned tenant.  This subtest resolves the rate through that same
# charge-path function (not a direct plan read) and asserts it equals the
# displayed rate -- the definition of done for #267: one source, no drift.
# ---------------------------------------------------------------------------
subtest 'rate-consistency: displayed rate equals charged rate' => sub {
    my $slug = $run_data->{subdomain};
    ok $slug, "provisioned tenant slug available ($slug)";

    # Charged rate via the real charge-path resolver, as a percent.
    my $fraction = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant(
        $db, $slug
    );
    my $charged_rate = $fraction * 100;

    ok defined($displayed_rate_str),
        'extracted a numeric rate from the review page HTML';

    my $displayed_rate = defined($displayed_rate_str) ? ($displayed_rate_str + 0) : undef;

    # Both values printed as diagnostics so any drift is visible in prove -v output.
    diag "displayed_rate (from review page HTML): ${\( $displayed_rate // 'undef' )}%";
    diag "charged rate (via revenue_share_fraction_for_tenant): ${charged_rate}%";

    is $displayed_rate, $charged_rate,
        'displayed plan rate matches the charged rate (both plan-driven, #267)';
};

$test_db->cleanup_test_database;
