# Alex User Journeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four journey-test legs under `t/user-journeys/alex/` proving the platform-owner outcomes: health automation, activate+collect, platform billing, and the signup funnel producing a working tenant.

**Architecture:** Pure test additions (no production code) following the existing `t/user-journeys/` conventions: per-file `Test::Registry::DB`, `Test::Registry::Mojo`, real workflows over HTTP, Stripe intercepted at the `Registry::Service::Stripe` seam. Build order is cheap-first per the spec: Leg 4 → Leg 2 → Leg 3 → Leg 1 (staged).

**Tech Stack:** Perl 5.42, Test::More, Test::Registry::{DB,Mojo,Helpers,Fixtures}, Mojo::JSON, Digest::SHA (webhook signing).

**Spec:** `docs/superpowers/specs/2026-06-11-alex-user-journeys-design.md` (same branch — READ IT FIRST; its decisions are binding).

**Branch / worktree:** `feature/alex-user-journeys` in `/home/perigrin/dev/Registry/.claude/worktrees/lifecycle`.

---

## Project conventions you must follow

- Read repo `CLAUDE.md`. Highlights: 100% pass rate, pristine output (expected warns must be captured), `carton exec prove -lv t/path` (always `-l`), never `--no-verify`, no mock modes or test-only methods in production code, ABOUTME headers on new files.
- Journey-test idioms (READ these before writing anything):
  - `t/user-journeys/morgan/01-program-management.t` — the leg shape: own DB, `$ENV{DB_URL} = $test_db->uri`, workflow import from YAML skipping drafts, `Test::Registry::Mojo->new('Registry')`, walk via `workflow_url`/`workflow_process_step_url`.
  - `t/controller/tenant-signup-data-flow.t` — the funnel walk backbone: `$t->app->helper(dao => sub { $db })` pins the app to the test DB; POST `/tenant-signup` → 302 → profile (`name`/`description`/`billing_email`) → users (`admin_name`/`admin_email`/`admin_username`/`admin_user_type`) → pricing → review. GET each page before POSTing (session/CSRF).
  - `t/e2e/tenant-onboarding.t` — registration over HTTP: `summer-camp-registration` via `workflow_process_step_url`, `account-check` step (`action => 'create_account'` then `authenticate_as($t,$user)` + `action => 'continue_logged_in'`), `Family->add_child`, then select-children / session-selection / payment steps.
  - `t/lib/Test/Registry/Helpers.pm` — `workflow_url`, `workflow_process_step_url`, `authenticate_as`, `import_all_workflows`, `process_workflow`.
  - `t/dao/payment-step-readiness-gate.t` — tenant + paid-session fixtures and the gate's expected error text.
  - `t/integration/tenant-paid-enrollment.t` — Stripe seam interception (`local *Registry::Service::Stripe::create_payment_intent`), fee derivation (`application_fee_cents(_to_cents($PLAN_AMOUNT))`), synthesizing `payment_intent.succeeded` from captured params.
  - `t/job/process-waitlist-tenant.t` + `t/job/waitlist-expiration-tenant.t` — MockLogger/MockJob/MockApp shims, tenant provisioning, sweep assertions.
- The `TenantPayment` payment step's test seam (production code, `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm:43-46,283-294`): POST `collect_payment_method => 1, setup_intent_id => 'seti_test_...'` → `handle_setup_completion` → `_provision_tenant` → `next_step => 'complete'`. The seti_test branch wins on **dispatch order** (it is checked before the no-keys branch), so Stripe env keys are irrelevant to this POST — set dummy keys only where a leg exercises the Stripe service path (Leg 2's `create_payment_intent` interception).
- **Fresh DBs have ZERO platform pricing relationships** (issue #268): `create-default-pricing-relationships.sql` is orphaned from `sqitch.plan`, so `PricingPlanSelection` finds no plans, renders no radios, and silently skips. Any leg that needs plan selection must first seed a platform relationship fixture (Task 3 shows the INSERT).
- Webhook signing (`lib/Registry/Controller/Webhooks.pm::_verify_stripe_signature`): header `stripe-signature: t=<epoch>,v1=<hmac>` where `<hmac> = hmac_sha256_hex("<epoch>.<raw_json_body>", $ENV{STRIPE_WEBHOOK_SECRET})`; timestamp within 300s.
- `ag` returns false negatives under `.claude/worktrees/` — verify any negative search result with `grep -r`.
- Journey failure philosophy (spec): a red assertion against a real flow is a FINDING — fix small/obvious bugs in-branch (own commit), file issues otherwise. Never weaken an assertion; TODO only with an issue reference.

## File structure

| File | Responsibility |
| --- | --- |
| `t/user-journeys/alex/04-platform-health.t` | Leg 4: sweeps process tenants, bad row isolated, /health |
| `t/user-journeys/alex/02-activate-and-collect.t` | Leg 2: gate → activate (row + signed webhook) → charge → complete |
| `t/user-journeys/alex/03-platform-billing.t` | Leg 3: minimal-data funnel walk → billing artifacts + #267 TODO drift assertion |
| `t/user-journeys/alex/01-acquire-tenant.t` | Leg 1: full funnel walk (stage 1) + working-tenant assertions (stage 2) |
| `t/lib/` helper | ONLY if Legs 1+3 fixture setup genuinely converges (YAGNI) |

No production files change. If a leg surfaces a production bug whose fix is small and obvious, fix it in its own commit with its own targeted test evidence; otherwise `gh issue create` and reference it.

---

### Task 1: Leg 4 — `t/user-journeys/alex/04-platform-health.t`

**Files:** Create `t/user-journeys/alex/04-platform-health.t`

- [ ] **Step 1: Write the test.** Skeleton (adapt mechanics from the two `t/job/*-tenant.t` files — copy their fixture/shim approach exactly):

```perl
#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: the automation runs without him.
# ABOUTME: Tenant-aware sweeps process every tenant, isolate bad rows, and /health probes the DB.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok subtest )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::Job::ProcessWaitlist;
use Registry::Job::WaitlistExpiration;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Tenant A: has sweepable state (offered waitlist entry, past expires_at;
# cancelled enrollment with a waiting entry) -- build per the t/job fixtures.
# Tenant B: provisioned, no waitlist state.
# Bad row: INSERT INTO registry.tenants (name, slug) a slug with NO schema
# (the #265 shape) -- defense-in-depth: the sweep must never let one bad row
# break other tenants, regardless of whether such rows turn out to be legal.

# 1. Sweeps reach tenant A's state and survive tenant B + the bad row:
#    capture per-tenant dispatch with the local-* interception idiom from
#    t/job/process-waitlist-tenant.t; assert A and B slugs were processed,
#    'registry' was not, and perform() completed despite the bad row
#    (MockJob's finish called, not fail).
# 2. Real effect in tenant A: the expired offer flipped to 'expired'
#    (WaitlistExpiration) -- assert on the tenant connection.
# 3. /health: my $t = Test::Registry::Mojo->new('Registry');
#    $t->get_ok('/health')->status_is(200)->json_is('/status','ok')->json_is('/db','ok');
```

The bad-row beat needs a real `perform()` run (not just interception) so the try/catch isolation is exercised. The `t/job` shims are no-op stubs — EXTEND them here: `MockLogger->error` pushes to an array, `MockJob` records whether `finish` or `fail` was called. Assert the captured error mentions the bad slug (`like`) and that `finish` (not `fail`) fired — pristine output, errors land in the captured logger, never STDERR. Add `like` to the Test::More import list and end with `$test_db->cleanup_test_database`.
- [ ] **Step 2: Run it.** `carton exec prove -lv t/user-journeys/alex/04-platform-health.t`. Expected: PASS (these behaviors all exist). Any red = finding (investigate before touching the test).
- [ ] **Step 3: Run the sibling suites** to prove no interference: `carton exec prove -lr t/job/`.
- [ ] **Step 4: Commit** (`Add Alex journey leg 4: platform health automation`).

### Task 2: Leg 2 — `t/user-journeys/alex/02-activate-and-collect.t`

**Files:** Create `t/user-journeys/alex/02-activate-and-collect.t`

- [ ] **Step 1: Write the test.** Structure (fixtures from `t/dao/payment-step-readiness-gate.t`, HTTP walk from `t/e2e/tenant-onboarding.t`):

```perl
# ABOUTME: Alex (platform owner) journey: activating a tenant's Connect account
# ABOUTME: unlocks paid enrollment and the platform fee is collected at charge time.
```

1. **Fixtures:** provision tenant (NOT ready); paid session + pricing plan (`my $PLAN_AMOUNT = 150.00`); import workflows into the tenant schema (provision copies them — verify; if `summer-camp-registration` is missing in the tenant schema, import the YAML into the tenant dao the way the gate test does). Pin the app to the TENANT dao: `$t->app->helper(dao => sub { $tenant_dao })` (the data-flow idiom). `local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy'; local $ENV{STRIPE_PUBLISHABLE_KEY} = 'pk_test_dummy'; local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_journey';`
2. **Gated:** parent account via the `account-check` step over HTTP (`create_account` → `authenticate_as` → `continue_logged_in`), `Family->add_child`, walk select-children/session-selection to the payment step (exact form data: crib from `t/e2e/tenant-onboarding.t`'s continuation), POST the payment step with `agreeTerms` → assert the response/run shows the gate error (`qr/not yet available/i`) and **no payment row in tenant nor registry schema**.
3. **Activate:** (a) `UPDATE registry.tenants SET stripe_connect_account_id='acct_journey', stripe_charges_enabled=false, stripe_details_submitted=false WHERE slug=?` (the runbook step); (b) deliver `account.updated` **over HTTP with a real signed payload**:

```perl
use Mojo::JSON qw(encode_json);
use Digest::SHA qw(hmac_sha256_hex);
my sub post_signed_webhook ($t, $event) {
    my $payload = encode_json($event);
    my $ts      = time();
    my $sig     = hmac_sha256_hex("$ts.$payload", $ENV{STRIPE_WEBHOOK_SECRET});
    return $t->post_ok('/webhooks/stripe',
        { 'stripe-signature' => "t=$ts,v1=$sig", 'Content-Type' => 'application/json' },
        $payload);
}
post_signed_webhook($t, {
    id   => 'evt_journey_acct_' . $$,
    type => 'account.updated',
    data => { object => { id => 'acct_journey',
                          charges_enabled => \1, details_submitted => \1 } },
})->status_is(200);
# assert registry.tenants row now ready (stripe_connect_ready via fresh Tenant load)
```

   Note: each event id must be unique (the `webhook_events` dedup claims it).
4. **Collect:** intercept `local *Registry::Service::Stripe::create_payment_intent` (capture + return `{ id => 'pi_journey', client_secret => 'cs_journey' }`); retry the payment-step POST → assert captured params: `transfer_data[destination] eq 'acct_journey'`, `on_behalf_of eq 'acct_journey'`, `application_fee_amount == Registry::DAO::Payment::application_fee_cents(Registry::DAO::Payment::_to_cents($PLAN_AMOUNT))`, bracket keys `metadata[payment_id]`/`metadata[tenant_slug]` present; payment row exists in the tenant schema, none in registry.
5. **Complete:** synthesize `payment_intent.succeeded` from the CAPTURED params (`payment_id`/`tenant_slug` read back out of the bracket keys — the integration test's proof shape) and deliver via `post_signed_webhook` → 200; assert payment `completed` and enrollment row exist in the tenant schema; registry has neither.

- [ ] **Step 2: Run it.** Expected: PASS end to end (all behaviors shipped). Reds are findings — the most likely one is the HTTP walk of `summer-camp-registration` inside a *tenant* schema (the e2e runs it in a different context); investigate honestly, fix-or-file.
- [ ] **Step 3: Regression:** `carton exec prove -lr t/controller/webhook-tenant-payment-finalization.t t/integration/tenant-paid-enrollment.t t/dao/payment-step-readiness-gate.t`.
- [ ] **Step 4: Commit.**

### Task 3: Leg 3 — `t/user-journeys/alex/03-platform-billing.t`

**Files:** Create `t/user-journeys/alex/03-platform-billing.t`

- [ ] **Step 1: Write the test.** FIRST seed the platform pricing relationship that signup needs (fresh DBs have none — issue #268; crib the shape from the orphaned `sql/deploy/create-default-pricing-relationships.sql:64-83`):

```perl
# Fresh deploys carry no platform pricing relationships (issue #268), so the
# pricing step would render no plans and silently skip. Seed the relationship
# for the seeded 2% plan, mirroring the orphaned default-relationships migration.
my $plan_id = $db->query(q{
    SELECT id FROM registry.pricing_plans
    WHERE pricing_model_type = 'percentage' AND target_type = 'tenant' LIMIT 1
})->hash->{id};
$db->query(q{
    INSERT INTO registry.pricing_relationships (provider_id, consumer_id, pricing_plan_id, status)
    VALUES ('00000000-0000-0000-0000-000000000000', ?, ?, 'active')
}, $consumer_id, $plan_id);
```

  (Verify the exact column list and whether `consumer_id` may be the platform UUID/NULL for an offer-to-all relationship by reading the orphaned migration and `PricingPlanSelection::prepare_pricing_data` — adapt the INSERT to what the listing query actually matches.) Then walk `tenant-signup` from the start over HTTP with **minimal form data** (same walk shape as Leg 1, registry-context dao pinned via the helper):
  - POST `/tenant-signup` → profile: submit minimal data but ALWAYS include `name` (`_provision_tenant` falls back to a generic 'Organization' tenant name without it, which would muddy the later assertions); RECORD what each step requires vs accepts empty — this feeds the friction inventory → users (minimal admin fields, `admin_user_type => 'admin'` to avoid the invite-warn) → pricing: GET the page, assert the seeded plan renders, select it with `selected_plan_id => $plan_id` (radio `name="selected_plan_id"`, `templates/tenant-signup/pricing.html.ep:99`; consumed via `exists $form_data->{selected_plan_id}` in `PricingPlanSelection::process`) → review → payment: POST `collect_payment_method => 1, setup_intent_id => 'seti_test_journey'` → complete.
  - **Assertions:**
    1. Run data carries `selected_pricing_plan`; the provisioned tenant row has `stripe_subscription_id` (`sub_test_…`), `billing_status` = `trial`, `trial_ends_at` set.
    2. **#267 dependency comment:** assert (documented, with the issue link) that NO tenant↔plan record exists post-signup — `TODO`-free, asserting current reality so #267's landing flips it consciously: assert absence now, with a comment that #267 strengthens this to assert the persisted link.
    3. **Rate-consistency drift (TODO #267):** extract the displayed rate from the pricing page HTML for the selected plan; compare to `Registry::DAO::Payment::REVENUE_SHARE_PERCENT`. Wrap in `TODO: { local $TODO = 'rate is constant-driven until #267; seeded plan advertises 2%'; ... }` — expected red, the diagnostics print both values.
  - State the recurring-billing non-goal (#263) in a comment.
- [ ] **Step 2: Run it.** Expected: PASS with the TODO red visible in diagnostics. Friction notes: collect the required-vs-empty field observations into comments at each step (input to Task 5's issue).
- [ ] **Step 3: Regression:** `carton exec prove -lr t/controller/tenant-signup-data-flow.t t/dao/tenant-payment-workflow.t`.
- [ ] **Step 4: Commit.**

### Task 4: Leg 1 stage 1 — funnel walk (`t/user-journeys/alex/01-acquire-tenant.t`)

**Files:** Create `t/user-journeys/alex/01-acquire-tenant.t`

- [ ] **Step 1: Write the walk.** Full `tenant-signup` over HTTP with REALISTIC (non-minimal) data — Portland-Art-Collective-style from the data-flow test — through landing → profile → users → pricing → review → **payment (`seti_test`) → complete**. Seed the platform pricing relationship first (the Task 3 fixture — fresh DBs offer no plans, issue #268) and select the plan with `selected_plan_id`. Stage 1 asserts only HTTP-level health: every POST 302s to the expected next step (`->header_like(Location => qr/...$/)`), the complete page renders 200. Keep the team admin-only (the invite-pending `warn` hazard) OR capture warns if testing invited members.
- [ ] **Step 2: Run it.** This crosses payment→complete over HTTP for the first time. Reds here are the spec's predicted findings: diagnose (the run's `latest_step`, response content), fix small/obvious in their own commits, `gh issue create` for anything larger, and only then stabilize the walk. Do NOT proceed to Task 5 with a red walk.
- [ ] **Step 3: Commit** the walk (plus any fix commits separately).

### Task 5: Leg 1 stage 2 — working-tenant assertions + friction inventory

**Files:** Modify `t/user-journeys/alex/01-acquire-tenant.t`

- [ ] **Step 1: Add the outcome assertions** after the walk:
  1. Tenant row + schema exist; tenant schema has workflows (`SELECT count(*) FROM <slug>.workflows` > 0 via explicit qualification from the registry connection).
  2. Signup users are dual-resident (same id in `registry.users` and `<slug>.users`).
  3. Storefront serves: fresh `Test::Registry::Mojo`, request `/` with `Host: <slug>.localhost` (`$t->get_ok('/' => { Host => "$slug.localhost" })`) → 200 and tenant name in content. (`_base_domains` includes `localhost`; the tenant resolver's schema-existence check passes post-provision.)
- [ ] **Step 2: Run the full leg.** Fix-or-file any reds per the philosophy.
- [ ] **Step 3: File the funnel-friction issue** (`gh issue create`, labels `enhancement,frontend,low-impact`): the per-step required-vs-accepts-empty inventory from Legs 1+3 walks, noting which fields downstream code consumes (grep the step classes for each field name); explicit framing that removal is decided field-by-field as separate product changes. Reference the spec.
- [ ] **Step 4: Commit** (mention the issue number).

### Task 6: Whole-suite verification

- [ ] **Step 1:** `carton exec prove -lv t/user-journeys/alex/` — all four legs green/pristine (Leg 3's TODO red visible but the file passes).
- [ ] **Step 2:** `carton exec prove -lr t/user-journeys/` — all persona suites green.
- [ ] **Step 3:** `carton exec ./registry workflow import registry && carton exec prove -lr t/` — full suite 100%. Paste the summary.
- [ ] **Step 4: Commit** anything outstanding; report the branch ready for PR.

---

## Verification (whole feature)

1. Full suite 100% (Task 6 evidence).
2. Spec acceptance: each spec section's assertions exist in the corresponding leg (the final reviewer walks spec §Design vs the four files).
3. The friction-inventory issue exists and cites per-field evidence.
4. Any funnel findings from Leg 1 are fixed in-branch (with their own commits/tests) or filed with issue references; no weakened assertions; the only TODO is Leg 3's #267-gated drift assertion.
