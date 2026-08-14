#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: activating a tenant's Connect account
# ABOUTME: unlocks paid enrollment and the platform fee is collected at charge time.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is like ok subtest )];
defer { done_testing };

use Mojo::JSON     qw(encode_json);
use Mojo::Promise;
use Digest::SHA    qw(hmac_sha256_hex);
use Mojo::Home;
use YAML::XS qw(Load);
use DateTime;

use Test::Mojo;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(
    workflow_url
    workflow_process_step_url
    authenticate_as
);

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;

# ---------------------------------------------------------------------------
# Stripe env: intercept at the service seam; never hit the network.
# STRIPE_WEBHOOK_SECRET is mandatory for the signature-verification path.
# ---------------------------------------------------------------------------
local $ENV{STRIPE_SECRET_KEY}       = 'sk_test_dummy';
local $ENV{STRIPE_PUBLISHABLE_KEY}  = 'pk_test_dummy';
local $ENV{STRIPE_WEBHOOK_SECRET}   = 'whsec_test_journey';

# ---------------------------------------------------------------------------
# Database setup
# ---------------------------------------------------------------------------
my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;    # registry-schema DAO
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

my $PLAN_AMOUNT_CENTS = 15_000;

# Import all non-draft workflows into the registry schema first.  Tenant
# provisioning copies registry workflows via copy_workflow, so the registry
# schema must have them before provision is called.
{
    my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
    for my $file (@files) {
        my $yaml = $file->slurp;
        next if Load($yaml)->{draft};
        Registry::DAO::Workflow->from_yaml($dao, $yaml);
    }
}

# Provision tenant -- NOT Stripe Connect ready yet.
my $slug = 'ac_tenant_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username  => "ac_admin_$$",
    email     => "ac_admin_$$\@test.example",
    name      => 'AC Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "AC Tenant $$",
    slug  => $slug,
    users => [ $admin ],
});
ok $tenant, 'tenant provisioned (not yet Stripe Connect ready)';
ok !$tenant->stripe_connect_ready, 'precondition: tenant not Stripe Connect ready';

# Link the tenant to the seeded 2% revenue-share plan so the charge-time
# resolver applies a 2% fee. A freshly provisioned tenant has
# platform_pricing_plan_id NULL (the one-time backfill ran before it existed),
# which would otherwise resolve to the Free 0% plan.
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

# Tenant-schema DAO
my $tenant_dao = Registry::DAO->new(url => $test_db->uri, schema => $slug);
my $tenant_db  = $tenant_dao->db;

# Verify that provision copied summer-camp-registration into the tenant schema.
my ($reg_wf) = $tenant_dao->find(Workflow => { slug => 'summer-camp-registration' });
ok $reg_wf, 'summer-camp-registration workflow present in tenant schema';

# Build location / program / event / session / pricing fixtures.
my $location = Registry::DAO::Location->create($tenant_db, {
    name         => 'AC Studio',
    address_info => { street_address => '1 AC Blvd', city => 'T', state => 'TX', postal_code => '78701' },
    metadata     => {},
});

my $teacher = Registry::DAO::User->create($tenant_db, {
    name      => 'AC Teacher',
    username  => "ac_teacher_$$",
    email     => "ac_teacher_$$\@test.com",
    user_type => 'staff',
});

my $future_start = DateTime->now->add(days => 30)->ymd;
my $future_end   = DateTime->now->add(days => 37)->ymd;

my $project = Registry::DAO::Project->create($tenant_db, {
    name              => 'AC Summer Camp',
    slug              => "ac_camp_$$",
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $event = Registry::DAO::Event->create($tenant_db, {
    time        => "$future_start 09:00:00",
    duration    => 420,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    capacity    => 20,
    metadata    => {},
});

my $session = Registry::DAO::Session->create($tenant_db, {
    name       => 'AC Week 1',
    start_date => $future_start,
    end_date   => $future_end,
    status     => 'published',
    capacity   => 20,
    metadata   => {},
});
$session->add_events($tenant_db, $event->id);

Registry::DAO::PricingPlan->create($tenant_db, {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount_cents => $PLAN_AMOUNT_CENTS,
});

# ---------------------------------------------------------------------------
# App setup: pin the app to the TENANT dao so all workflow HTTP requests are
# resolved against the tenant schema.  The tenant helper still reads the Host
# header to determine the slug; we send <slug>.localhost for workflow GETs/POSTs
# so the controller sets __tenant_slug in the run data.
# ---------------------------------------------------------------------------
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $tenant_dao });

# Webhook calls use a raw Test::Mojo client that shares the same app instance
# but bypasses Test::Registry::Mojo's CSRF-injection logic.
# CSRF validation is already bypassed for /webhooks/ paths in the app
# (before_dispatch hook: `return if $c->req->url->path =~ m{^/webhooks/}`),
# but Test::Registry::Mojo appends `form => { csrf_token => ... }` to bare
# POST calls that have no form body.  With a raw JSON body this would result
# in 3+ args to build_tx with the JSON string as the generator key, crashing
# Mojo::UserAgent::Transactor line 172.  Using the parent Test::Mojo directly
# avoids that injection while sharing the same Mojolicious app/session.
my $t_webhook = Test::Mojo->new($t->app);

# ---------------------------------------------------------------------------
# Helper: post a signed Stripe webhook event.
# Signature format: "t=<epoch>,v1=<hmac_sha256_hex(epoch.payload, secret)>"
# Timestamp must be within 300 s of now (verified in _verify_stripe_signature).
# Each event id must be unique (registry.webhook_events dedup).
# ---------------------------------------------------------------------------
my sub post_signed_webhook ($tw, $event) {
    my $payload = encode_json($event);
    my $ts      = time();
    my $sig     = hmac_sha256_hex("$ts.$payload", $ENV{STRIPE_WEBHOOK_SECRET});
    return $tw->post_ok('/webhooks/stripe',
        { 'stripe-signature' => "t=$ts,v1=$sig", 'Content-Type' => 'application/json' },
        $payload);
}

# Host header for the tenant subdomain (drives __tenant_slug in new_run).
my %tenant_host = ( Host => "$slug.localhost" );

# ---------------------------------------------------------------------------
# Walk helpers and cross-subtest state
# ---------------------------------------------------------------------------

# Reload the run fresh from the DB.
my sub reload_run ($run) {
    my ($fresh) = $tenant_dao->find(WorkflowRun => { id => $run->id });
    return $fresh;
}

# File-scope state threaded through the four subtests.
my ($journey_parent_id, $journey_child_id, $journey_run_id);

# ---------------------------------------------------------------------------
# Phase 1: Walk the registration workflow to the payment step, confirm gate.
# ---------------------------------------------------------------------------
subtest 'gated: unready tenant blocks paid enrollment' => sub {

    # Start the workflow run: POST to /<slug> with the tenant host header.
    $t->post_ok(workflow_url($reg_wf), \%tenant_host, form => {})->status_is(302);
    my $run = $reg_wf->latest_run($tenant_db);
    ok $run, 'workflow run created';

    # account-check: create_account
    my $step = $run->next_step($tenant_db);
    is $step->slug, 'account-check', 'at account-check step';

    $t->post_ok(
        workflow_process_step_url($reg_wf, $run, $step),
        \%tenant_host,
        form => {
            action   => 'create_account',
            username => "ac_parent_$$",
            email    => "ac_parent_$$\@example.com",
            name     => 'AC Parent',
        }
    )->status_is(302);

    my $parent = Registry::DAO::User->find($tenant_db, { username => "ac_parent_$$" });
    ok $parent, 'parent account created in tenant schema';

    # Simulate magic-link auth and continue
    authenticate_as($t, $parent);
    $run  = reload_run($run);
    $step = $run->next_step($tenant_db);
    is $step->slug, 'account-check', 'still at account-check (continue_logged_in)';

    $t->post_ok(
        workflow_process_step_url($reg_wf, $run, $step),
        \%tenant_host,
        form => { action => 'continue_logged_in' }
    )->status_is(302);

    # Add child via DAO (same pattern as tenant-onboarding e2e)
    my $child = Registry::DAO::Family->add_child($tenant_db, $parent->id, {
        child_name        => 'AC Child',
        birth_date        => '2018-06-01',
        grade             => '3',
        medical_info      => {},
        emergency_contact => { name => 'AC Emergency', phone => '512-555-0100' },
    });
    ok $child, 'child created';

    # select-children
    $run  = reload_run($run);
    $step = $run->next_step($tenant_db);
    is $step->slug, 'select-children', 'at select-children step';

    $t->post_ok(
        workflow_process_step_url($reg_wf, $run, $step),
        \%tenant_host,
        form => {
            action               => 'continue',
            "child_${\$child->id}" => 1,
        }
    )->status_is(302);

    # camper-info
    $run  = reload_run($run);
    $step = $run->next_step($tenant_db);
    is $step->slug, 'camper-info', 'at camper-info step';

    $t->post_ok(
        workflow_process_step_url($reg_wf, $run, $step),
        \%tenant_host,
        form => { childName => 'AC Child' }
    )->status_is(302);

    # session-selection
    $run  = reload_run($run);
    $step = $run->next_step($tenant_db);
    is $step->slug, 'session-selection', 'at session-selection step';

    $t->post_ok(
        workflow_process_step_url($reg_wf, $run, $step),
        \%tenant_host,
        form => {
            action                      => 'select_sessions',
            "session_for_${\$child->id}" => $session->id,
        }
    )->status_is(302);

    # payment step -- gate should fire
    $run  = reload_run($run);
    $step = $run->next_step($tenant_db);
    is $step->slug, 'payment', 'at payment step';

    # The gate fires: stays on the payment step (redirect back to same URL)
    # or returns a 200 with errors rendered inline.  Both modes are accepted
    # deliberately -- the controller's error rendering varies with request
    # type, and the load-bearing invariants are the ones asserted below:
    # the run stays on the payment step and no payment row exists anywhere.
    $t->post_ok(
        workflow_process_step_url($reg_wf, $run, $step),
        \%tenant_host,
        form => { agreeTerms => 1 }
    );

    my $response_code = $t->tx->res->code;
    ok $response_code == 302 || $response_code == 200,
        "gate response is redirect or inline error ($response_code)";

    # If 302, follow to confirm it stays on the payment step
    if ($response_code == 302) {
        my $loc = $t->tx->res->headers->location;
        like $loc, qr/payment/, 'redirect stays on payment step URL';

        $t->get_ok($loc, \%tenant_host)->status_is(200)
          ->content_like(qr/not yet available/i, 'gate error visible in payment page');
    } else {
        $t->content_like(qr/not yet available/i, 'gate error visible in inline response');
    }

    # Reload run: must still be on payment step
    $run = reload_run($run);
    $step = $run->next_step($tenant_db);
    is $step->slug, 'payment', 'run stays on payment step after gate fires';

    # Zero payment rows in tenant schema
    my $tenant_pay_count = $tenant_db->select(
        'payments', ['id'], { user_id => $parent->id })->hashes->size;
    is $tenant_pay_count, 0, 'no payment row created in tenant schema when gate fires';

    # Zero payment rows in registry schema (qualified table)
    my $registry_pay_count = $db->select(
        'registry.payments', ['id'], { user_id => $parent->id })->hashes->size;
    is $registry_pay_count, 0, 'no payment row in registry schema when gate fires';

    # Thread state to later phases via file-scope variables.
    $journey_parent_id = $parent->id;
    $journey_child_id  = $child->id;
    $journey_run_id    = $run->id;
};

# ---------------------------------------------------------------------------
# Phase 2: Activate -- record the account then fire the signed webhook.
# ---------------------------------------------------------------------------
subtest 'activate: account row + signed account.updated webhook' => sub {
    # (a) Record the Stripe connected account id; booleans stay false.
    # The runbook step: platform owner pastes the account id into the tenant row.
    # Readiness is supplied by Stripe's account.updated webhook, not by us.
    $db->query(
        q{UPDATE registry.tenants
          SET stripe_connect_account_id = 'acct_journey'
          WHERE slug = ?},
        $slug,
    );

    # Reload and confirm not yet ready (booleans still false)
    my $row = $db->query('SELECT * FROM registry.tenants WHERE slug = ?', $slug)->hash;
    my $pre = Registry::DAO::Tenant->new(%$row);
    ok !$pre->stripe_connect_ready,
        'tenant not ready after account id recorded (booleans still false)';

    # (b) Deliver signed account.updated over HTTP.
    # The webhook controller uses $self->app->dao (pinned to $tenant_dao).
    # _process_account_updated does: $dao->db->query('UPDATE registry.tenants ...')
    # $tenant_dao->db has search_path = $slug, public -- but registry.tenants is
    # qualified, so the update reaches the right table.  We verify empirically below.
    my $acct_event_id = 'evt_journey_acct_' . $$;
    post_signed_webhook($t_webhook, {
        id   => $acct_event_id,
        type => 'account.updated',
        data => { object => {
            id                => 'acct_journey',
            charges_enabled   => \1,
            details_submitted => \1,
        } },
    })->status_is(200, 'account.updated webhook accepted');

    # Assert flags were set
    my $row_after = $db->query('SELECT * FROM registry.tenants WHERE slug = ?', $slug)->hash;
    my $after_tenant = Registry::DAO::Tenant->new(%$row_after);
    ok $after_tenant->stripe_connect_ready,
        'tenant is stripe_connect_ready after account.updated webhook';
};

# ---------------------------------------------------------------------------
# Phase 3: Collect -- intercept Stripe, retry payment step, verify params.
# ---------------------------------------------------------------------------
my $captured_params;

subtest 'collect: payment step passes, correct Stripe Connect params captured' => sub {
    my ($run)  = $tenant_dao->find(WorkflowRun => { id => $journey_run_id });
    my $step   = $run->next_step($tenant_db);
    is $step->slug, 'payment', 'run is still on payment step (gate refusal did not advance it)';

    # Intercept the async intent seam; capture params and return a fixture
    # intent. The controller renders only once this promise settles, so the
    # request also exercises the render_later path.
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub {
            my ($self_stripe, $params) = @_;
            $captured_params = $params;
            return Mojo::Promise->resolve(
                { id => 'pi_journey', client_secret => 'cs_journey' });
        };

        # When payment intent is created, the step stays on the payment page
        # (status 200) to render the Stripe card-entry form with the
        # client_secret.  A redirect (302) only comes from handle_payment_callback
        # after the card is submitted with payment_intent_id.  We assert 200 here
        # and verify the intent was created via the captured params below.
        $t->post_ok(
            workflow_process_step_url($reg_wf, $run, $step),
            \%tenant_host,
            form => { agreeTerms => 1 }
        )->status_is(200, 'payment step renders Stripe form after passing gate')
         ->content_like(qr/id="payment-form"/,
            'the card-entry form the parent has to use is on the page')
         ->content_like(qr/cs_journey/,
            'the fresh client_secret reaches the Stripe Elements init');
    }

    ok $captured_params,
        'Stripe create_payment_intent_async was called and params captured';

    # Connect routing params
    is $captured_params->{'transfer_data[destination]'}, 'acct_journey',
        'transfer_data[destination] is the connected account id';
    is $captured_params->{'on_behalf_of'}, 'acct_journey',
        'on_behalf_of is the connected account id';

    # Application fee: 2% (tenant's linked plan) of 15000 cents = 300 cents
    my $expected_fee = Registry::DAO::Payment::application_fee_cents($PLAN_AMOUNT_CENTS, 0.02);
    is $expected_fee, 300, q{sanity: expected fee is 300 cents (2% of 15000 cents)};
    is $captured_params->{'application_fee_amount'}, $expected_fee,
        'application_fee_amount matches platform 2% fee';

    # Bracket-notation metadata keys for webhook routing
    ok exists $captured_params->{'metadata[payment_id]'},
        'metadata[payment_id] bracket key present';
    ok exists $captured_params->{'metadata[tenant_slug]'},
        'metadata[tenant_slug] bracket key present';
    is $captured_params->{'metadata[tenant_slug]'}, $slug,
        'metadata[tenant_slug] value matches tenant slug';

    # Payment row must exist in tenant schema only
    my $tenant_pays = $tenant_db->select(
        'payments', ['id'], { user_id => $journey_parent_id })->hashes;
    is scalar @$tenant_pays, 1, 'exactly one payment row in the tenant schema';

    my $reg_pays = $db->select(
        'registry.payments', ['id'], { user_id => $journey_parent_id })->hashes;
    is scalar @$reg_pays, 0, 'no payment row in registry schema';
};

# ---------------------------------------------------------------------------
# Phase 4: Complete -- deliver signed payment_intent.succeeded, assert enrollment.
# ---------------------------------------------------------------------------
subtest 'complete: payment_intent.succeeded webhook finalizes payment and enrollment' => sub {
    ok $captured_params, 'captured Stripe params available for phase 4';

    # Synthesize the webhook from captured bracket-notation params.
    # This mirrors what Stripe echoes back: our bracket keys become nested
    # metadata on the intent object.
    my $payment_id  = $captured_params->{'metadata[payment_id]'};
    my $tenant_slug = $captured_params->{'metadata[tenant_slug]'};
    my $pi_id       = 'pi_journey';

    ok $payment_id,  'payment_id extracted from captured Stripe bracket params';
    ok $tenant_slug, 'tenant_slug extracted from captured Stripe bracket params';

    # Unique event id (dedup guard)
    my $pi_event_id = 'evt_journey_pi_' . $$ . '_1';
    post_signed_webhook($t_webhook, {
        id   => $pi_event_id,
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => $pi_id,
            metadata => {
                payment_id  => $payment_id,
                tenant_slug => $tenant_slug,
            },
        } },
    })->status_is(200, 'payment_intent.succeeded webhook accepted');

    # Payment must be completed in tenant schema
    my $payment = Registry::DAO::Payment->find($tenant_db, { id => $payment_id });
    ok $payment, 'payment found in tenant schema';
    is $payment->status, 'completed', 'payment status is completed';

    # Enrollment must exist in tenant schema
    my $enrollments = $tenant_db->select(
        'enrollments', '*', { payment_id => $payment_id })->hashes;
    is scalar @$enrollments, 1, 'exactly one enrollment created in tenant schema';
    is $enrollments->[0]{status}, 'active', 'enrollment status is active';

    # Neither completed payment nor enrollment in registry schema
    my $reg_enr = $db->select(
        'registry.enrollments', ['id'], { payment_id => $payment_id })->hash;
    ok !$reg_enr, 'enrollment NOT created in registry schema';

    my $reg_pay = $db->select(
        'registry.payments', ['id'], { id => $payment_id })->hash;
    ok !$reg_pay, 'payment NOT present in registry schema';
};

$test_db->cleanup_test_database;
