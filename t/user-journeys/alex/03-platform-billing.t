#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: Registry bills the tenant for the
# ABOUTME: platform subscription established during signup.

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
#   pricing     — 'selected_plan_id' required (must be a valid UUID for an
#                 active platform relationship; empty or absent silently skips).
#   review      — 'terms_accepted' required by the controller (Workflows.pm:337-
#                 358) BEFORE calling step->process; the step itself accepts
#                 empty body but the controller gate refuses without it.
#   payment     — 'collect_payment_method' + 'setup_intent_id' (seti_test…)
#                 trigger the test-mode provision path.
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

my $pricing_url = $t->tx->res->headers->location;
like $pricing_url, qr{/tenant-signup/[^/]+/pricing}, 'redirected to pricing step';

# -- Step: pricing (GET) -- assert the seeded plan renders ----------------
# This GET doubles as the #268 guard: if the seeded relationship is absent,
# prepare_pricing_data returns an empty list and the template renders no
# radio buttons, and this assertion catches that silently-broken path.
my $pricing_page = $t->get_ok($pricing_url)->status_is(200)->tx->res->body;

like $pricing_page, qr/selected_plan_id/,
    'pricing page renders at least one plan radio (seeded relationship visible, #268 guard)';
like $pricing_page, qr/Registry Revenue Share/,
    'pricing page shows the seeded 2% revenue-share plan name';

# -- Capture the displayed rate for the rate-consistency assertion below ----
# The plan description contains "2% of all customer payments"; the plan name
# contains "2%".  Extract the rate as a number for numeric comparison.
# (If the field ever gains a revenue_share_percent key, this pattern still
# works because the surrounding text will still mention the rate.)
my ($displayed_rate_str) = $pricing_page =~ /(\d+(?:\.\d+)?)\s*%\s*of\s+(?:all\s+)?customer\s+payments/i;
$displayed_rate_str //= do {
    # Fallback: extract the rate from the plan name "Revenue Share - N%"
    ($pricing_page =~ /Revenue Share[^%]*?(\d+(?:\.\d+)?)\s*%/i)[0];
};

# -- Step: pricing (POST) -- select the seeded plan ----------------------
$t->post_ok($pricing_url => form => {
    selected_plan_id => $plan_id,
})->status_is(302);

my $review_url = $t->tx->res->headers->location;
like $review_url, qr{/tenant-signup/[^/]+/review}, 'redirected to review step';

# -- Step: review ---------------------------------------------------------
# The controller (Workflows.pm:337-358) validates terms_accepted and checks
# for accumulated admin_name/admin_email/name in run data before advancing.
# terms_accepted is the only field the user must explicitly submit here;
# all other required data must have been collected in earlier steps.
$t->get_ok($review_url)->status_is(200);
$t->post_ok($review_url => form => {
    terms_accepted => 1,    # required by controller review-step validation
})->status_is(302);

my $payment_url = $t->tx->res->headers->location;
like $payment_url, qr{/tenant-signup/[^/]+/payment}, 'redirected to payment step';

# -- Step: payment (GET) --------------------------------------------------
$t->get_ok($payment_url)->status_is(200);

# -- Step: payment (POST via seti_test seam) ------------------------------
# POST collect_payment_method=1 + setup_intent_id=seti_test_… dispatches to
# handle_setup_completion -> _provision_tenant (TenantPayment.pm:43-46, 283-
# 294).  The seti_test branch wins on dispatch order before the no-keys
# branch, so Stripe env keys are irrelevant to this POST.
$t->post_ok($payment_url => form => {
    collect_payment_method => 1,
    setup_intent_id        => 'seti_test_billing_' . $$,
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
# Assertion 1a: the run carries selected_pricing_plan
# ---------------------------------------------------------------------------
subtest 'run data carries selected_pricing_plan' => sub {
    my $sel = $run_data->{selected_pricing_plan};
    ok $sel, 'selected_pricing_plan key present in workflow run data';
    is $sel->{id}, $plan_id,
        'selected_pricing_plan.id matches the plan we posted';
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

    like $tenant_row->{stripe_subscription_id}, qr/^sub_test_/,
        'stripe_subscription_id starts with sub_test_ (seti_test provision path)';
    is $tenant_row->{billing_status}, 'trial',
        'billing_status is "trial" on the seti_test path';
    ok defined($tenant_row->{trial_ends_at}),
        'trial_ends_at is set (not NULL)';
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
        'tenants.platform_pricing_plan_id equals the selected plan (#267 persisted link)';

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
# The pricing page advertises a rate (plan name "Registry Revenue Share - 2%"
# and description "2% of all customer payments").  The CHARGED rate is what the
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
        'extracted a numeric rate from the pricing page HTML';

    my $displayed_rate = defined($displayed_rate_str) ? ($displayed_rate_str + 0) : undef;

    # Both values printed as diagnostics so any drift is visible in prove -v output.
    diag "displayed_rate (from pricing page HTML): ${\( $displayed_rate // 'undef' )}%";
    diag "charged rate (via revenue_share_fraction_for_tenant): ${charged_rate}%";

    is $displayed_rate, $charged_rate,
        'displayed plan rate matches the charged rate (both plan-driven, #267)';
};

$test_db->cleanup_test_database;
