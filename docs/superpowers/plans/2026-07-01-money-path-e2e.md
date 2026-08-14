# Money-path E2E ("ready to take money") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Registry's parent-enrollment money path (Stripe Connect destination charges) works end-to-end against real Stripe test mode, close the idempotent-charge gap, and make refund fee behavior configurable per pricing plan.

**Architecture:** Two proof layers — a gated Perl suite that drives the real Stripe test-mode API server-side (owns invariants I1–I7) plus one thin Playwright browser smoke — added on top of two small money-path code fixes (idempotent charge creation; plan-configurable refund fee). Test-only infrastructure lives in `t/lib/`. A dedicated non-blocking CI workflow runs the real-Stripe suites only where secrets are available; everything self-skips without a Stripe key so local `prove -lr t/` and fork PRs stay 100% green.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::Pg, Test::More/Test::Registry::*, Sqitch (PostgreSQL migrations), Stripe API (test mode), Playwright (Node).

**Spec:** `docs/superpowers/specs/2026-06-21-money-path-e2e-design.md`

**Ordering (hard dependency DAG):** `Leg 0 → {Leg A, Leg B} → Leg C → Leg D`; `Leg E` (doc fix) is independent. Each leg is one PR; perigrin merges.

---

## Conventions for every task

- Run the full-file tests with: `carton exec prove -lv t/path/to/file.t` (always `-l`, never `-r` alone).
- After a migration change, regenerate the test schema dump: `make test-schema`, and commit `sql/test-schema.sql`. `prove` loads the dump, not live `sql/`.
- Mocked unit/integration tests need NO Stripe key. The real-Stripe suite (Leg C) and the browser smoke (Leg D) self-skip unless `STRIPE_SECRET_KEY` is set.
- Object::Pad: methods take no explicit `$self`; use `field ... :param :reader`; use `isa` for type checks.
- Commit after every green step. Do not commit with `--no-verify`.

---

## Leg 0 — Feasibility spike: Custom test connected account → `charges_enabled`

**Why first:** The entire "no browser / no tunnel" Layer-1 architecture assumes we can bring a Stripe **test** connected account to `charges_enabled` purely via the API. Validate before building Leg C. This is a spike (no TDD); its deliverable is a documented, working recipe.

**Files:**
- Create: `docs/superpowers/notes/leg0-connect-account-recipe.md` (the validated recipe artifact)

- [ ] **Step 1: Authenticate the Stripe MCP (test mode).** Use the Stripe MCP tools available in-session. Confirm operations run against a **test** key (`sk_test_`). If only a live key is available, STOP and ask perigrin — never proceed against live.

- [ ] **Step 2: Create a Custom connected account and drive it to `charges_enabled`.** Via the Stripe MCP / API, create an account and request the capabilities a destination charge needs, then satisfy test-mode requirements. Starting recipe to validate:
  - `POST /v1/accounts` with `type=custom` (or v2 controller properties), `country=US`, `business_type=individual`, `capabilities[card_payments][requested]=true`, `capabilities[transfers][requested]=true`.
  - `tos_acceptance[date]`, `tos_acceptance[ip]`.
  - Prefill test individual data to clear `requirements.currently_due` (name, dob, address, ssn_last_4 test values, email, phone, url/mcc as required).
  - Attach a test external account (bank token, e.g. the Stripe test routing/account numbers).
  - Poll `GET /v1/accounts/{id}` until `charges_enabled == true` and both capabilities are `active` (they pass through `requested → pending → active`).

- [ ] **Step 3: Create the deliberately-NOT-ready variant** (for I5): an account created but left without `charges_enabled` (do not complete requirements). Record how to produce it.

- [ ] **Step 4: Sanity-check a destination charge against the ready account.** Create + confirm a PaymentIntent (`pm_card_visa`) with `transfer_data[destination]`, `on_behalf_of`, `application_fee_amount`; retrieve the charge; confirm `application_fee_amount` and `transfer_data.destination` are present. This proves the recipe is chargeable.

- [ ] **Step 5: Write the recipe artifact.** Record the exact, working sequence (fields, capability polling, the not-ready variant) in `docs/superpowers/notes/leg0-connect-account-recipe.md`. This is Leg C's build input.

- [ ] **Step 6: Decision gate.** If `charges_enabled` cannot be reached server-side, STOP and surface to perigrin — Layer 1 needs redesign. Otherwise commit the artifact.

```bash
git add docs/superpowers/notes/leg0-connect-account-recipe.md
git commit -m "Leg 0: validated Stripe test connected-account recipe (spike)"
```

---

## Leg A — Refund as a pricing-plan configuration

**Files:**
- Modify: `lib/Registry/PriceOps/RevenueShare.pm` (add `refund_application_fee_for_tenant`)
- Modify: `lib/Registry/DAO/Payment.pm` (extend `refund` + `refund_async`)
- Create: `sql/deploy/refund-application-fee-config.sql`, `sql/revert/refund-application-fee-config.sql`, `sql/verify/refund-application-fee-config.sql`
- Modify: `sql/sqitch.plan` (via `sqitch add`)
- Test: `t/dao/refund-application-fee.t`

### Task A1: Resolver `refund_application_fee_for_tenant`

- [ ] **Step 1: Write the failing test.** In `t/dao/refund-application-fee.t`, seed the platform Free plan (default) and a tenant linked to a plan whose `pricing_configuration` sets `refund_application_fee`. Assert:

```perl
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::PriceOps::RevenueShare;

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db; my $db = $dao->db;
# ... seed a tenant 'acme' linked to a plan with pricing_configuration
#     including {"refund_application_fee": false}
is Registry::PriceOps::RevenueShare::refund_application_fee_for_tenant($db, 'acme'),
   0, 'linked plan opting out returns false';
# ... a tenant 'nolink' with platform_pricing_plan_id NULL falls back to default (true)
is Registry::PriceOps::RevenueShare::refund_application_fee_for_tenant($db, 'nolink'),
   1, 'unlinked tenant falls back to platform default (true)';
```

- [ ] **Step 2: Run it, verify it fails** (`Undefined subroutine`). `carton exec prove -lv t/dao/refund-application-fee.t`

- [ ] **Step 3: Implement the resolver** in `lib/Registry/PriceOps/RevenueShare.pm`, mirroring `revenue_share_fraction_for_tenant`. Boolean semantics: `pricing_configuration->>'refund_application_fee'` is `'true'`/`'false'`; **default `true`** when the key is absent/null OR when the tenant has no linked plan (fall back to the platform default plan's setting, itself defaulting to true). Fail loud only on a malformed value.

```perl
# add to @EXPORT_OK: refund_application_fee_for_tenant
sub refund_application_fee_for_tenant ($db, $tenant_slug) {
    $db = $db->db if $db isa Registry::DAO;
    my $row = $db->query(q{
        SELECT p.pricing_configuration->>'refund_application_fee' AS raw
          FROM registry.tenants t
          JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
         WHERE t.slug = ?
    }, $tenant_slug)->hash;
    return _coerce_refund_flag($row->{raw}) if $row;      # linked plan
    return _platform_default_refund_flag($db);            # NULL FK / no tenant
}

sub _platform_default_refund_flag ($db) {
    my $r = $db->query(q{
        SELECT pricing_configuration->>'refund_application_fee' AS raw
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform' AND metadata->>'default' = 'true'
         LIMIT 1
    })->hash;
    # Absent default plan is a deployment bug for the *rate* resolver; for the
    # refund flag, absence of the KEY means default true.
    return 1 unless $r;
    return _coerce_refund_flag($r->{raw});
}

sub _coerce_refund_flag ($raw) {
    return 1 unless defined $raw;         # key absent -> default true
    return 1 if $raw eq 'true';
    return 0 if $raw eq 'false';
    die "refund_application_fee must be 'true' or 'false', got '$raw'";
}
```

- [ ] **Step 4: Run it, verify pass.**
- [ ] **Step 5: Commit.** `git commit -am "Leg A: add refund_application_fee_for_tenant resolver"`

### Task A2: Extend `Payment->refund` / `refund_async`

- [ ] **Step 1: Write the failing test** (append to `t/dao/refund-application-fee.t`). Intercept the Stripe service to capture refund params; assert a **tenant** payment (metadata has `tenant_slug`) sends `reverse_transfer => 1` and `refund_application_fee => <resolved>`, and a **registry** payment (no `tenant_slug`) sends neither.

```perl
no warnings 'redefine';
my %captured;
local *Registry::Service::Stripe::create_refund = sub ($s, $p) { %captured = %$p; return { id => 're_x' } };
# ... build a completed tenant payment with metadata->{tenant_slug} = 'acme'
$tenant_payment->refund($tdb);
ok exists $captured{reverse_transfer},        'tenant refund sets reverse_transfer';
is  $captured{refund_application_fee}, 0,      'tenant refund honors plan policy (acme opted out)';
# ... registry payment (no tenant_slug)
%captured = ();
$registry_payment->refund($db);
ok !exists $captured{reverse_transfer},        'registry refund unchanged';
ok !exists $captured{refund_application_fee},   'registry refund unchanged';
```

- [ ] **Step 2: Run it, verify it fails.**

- [ ] **Step 3: Implement.** In `lib/Registry/DAO/Payment.pm`, add a small helper that, for tenant destination-charge payments (detected by `tenant_slug` in `$metadata`, mirroring `_connect_params`), augments the refund params. Apply in both `refund` (sync) and `refund_async`.

```perl
# Connect refunds: for a destination charge the tenant received the tuition, so
# reverse the transfer; whether the platform also returns its application fee is
# the plan's policy. Registry/platform payments (no tenant_slug) are unchanged.
method _refund_connect_params ($db) {
    my $slug = ref $metadata eq 'HASH' ? $metadata->{tenant_slug} : undef;
    return () unless $slug && $slug ne 'registry';
    $db = $db->db if $db isa Registry::DAO;
    my $refund_fee =
        Registry::PriceOps::RevenueShare::refund_application_fee_for_tenant($db, $slug);
    return (
        reverse_transfer       => 1,
        refund_application_fee => $refund_fee ? 1 : 0,
    );
}
```
Then in `refund` / `refund_async`, merge `$self->_refund_connect_params($db)` into the params passed to `create_refund` / `create_refund_async`. (Partial-refund transfer/fee proportions are Stripe-managed — do not hand-roll proration.)

- [ ] **Step 4: Run it, verify pass.**
- [ ] **Step 5: Commit.** `git commit -am "Leg A: refund honors plan's refund_application_fee + reverse_transfer for tenant charges"`

### Task A3: Seed migration — declare `refund_application_fee` on seeded plans

- [ ] **Step 1: Add the sqitch change.** `carton exec sqitch add refund-application-fee-config -n "Declare refund_application_fee on seeded platform + tenant plans"`

- [ ] **Step 2: Write the deploy SQL** (`sql/deploy/refund-application-fee-config.sql`). Set the key explicitly (default is true; set explicitly for visibility) on the platform default plan and the tenant percentage plan(s), using `jsonb_set` and keeping existing keys:

```sql
BEGIN;
UPDATE registry.pricing_plans
   SET pricing_configuration =
       jsonb_set(pricing_configuration, '{refund_application_fee}', 'true'::jsonb, true)
 WHERE plan_scope = 'platform' AND metadata->>'default' = 'true';

-- NOTE: this targets ALL tenant percentage plans, not just the launch plan the
-- tenant-platform-pricing-plan backfill selected. That is intentional: every
-- percentage plan should declare the flag. Default is true regardless; this
-- makes it visible.
UPDATE registry.pricing_plans
   SET pricing_configuration =
       jsonb_set(pricing_configuration, '{refund_application_fee}', 'true'::jsonb, true)
 WHERE plan_scope = 'tenant' AND pricing_model_type = 'percentage';
COMMIT;
```
Write `sql/revert/...` (remove the key via `#-` operator) and a `sql/verify/...` that asserts the key is present.

- [ ] **Step 3: Deploy against a scratch DB + verify.** `carton exec sqitch deploy` / `verify` on a throwaway DB (local postgres :5432). Then `make test-schema` and commit `sql/test-schema.sql`.

- [ ] **Step 4: Run the full Leg A test file** to confirm resolver reads the seeded values. `carton exec prove -lv t/dao/refund-application-fee.t`
- [ ] **Step 5: Commit.** `git commit -am "Leg A: seed refund_application_fee on platform + tenant plans; regen test schema"`

---

## Leg B — Idempotent charge creation (I7)

**Design:** Two coordinated fixes so a double-submit/retry yields at most one charge:
1. A Stripe `Idempotency-Key` on charge creation, derived from a stable token on the Payment row (`metadata.idempotency_token`) — set once at row creation. Duplicate creation calls for the same token return the same PaymentIntent.
2. `create_payment` reuses the workflow run's existing Payment row instead of creating a new one on a repeated `agreeTerms` submit.
A deliberate retry-after-decline **rotates** the token so it produces a fresh charge.

**Files:**
- Modify: `lib/Registry/Service/Stripe.pm` (`_request_async`, `create_payment_intent[_async]` accept an idempotency key)
- Modify: `lib/Registry/DAO/Payment.pm` (generate/store token; send key; rotate on retry)
- Modify: `lib/Registry/DAO/WorkflowSteps/Payment.pm` (`create_payment` reuse; retry rotates token)
- Test: `t/dao/payment-idempotency.t`

### Task B1: Stripe service accepts an `Idempotency-Key`

- [ ] **Step 1: Write the failing test** (`t/dao/payment-idempotency.t`) that constructs `Registry::Service::Stripe`, monkeypatches its `$ua` request builder or asserts via a captured header that `create_payment_intent({... , _idempotency_key => 'k1'})` sets the `Idempotency-Key` header. (Follow the async transaction path in `_request_async`.)

- [ ] **Step 2: Run it, verify it fails.**

- [ ] **Step 3: Implement.** In `_request_async`, accept an optional idempotency key and add it to `$headers` as `'Idempotency-Key'`. Thread an optional key from `create_payment_intent_async` (pull `_idempotency_key` out of `$params` before sending so it is not form-encoded as a Stripe field).

- [ ] **Step 4: Run it, verify pass.**
- [ ] **Step 5: Commit.** `git commit -am "Leg B: Stripe service supports Idempotency-Key on payment intent creation"`

### Task B2: Payment stores + sends a stable idempotency token

- [ ] **Step 1: Write the failing test.** Assert `create_payment_intent` sends an `Idempotency-Key` derived from the payment's `metadata.idempotency_token`, that two calls on the same payment send the **same** key, and that `rotate_idempotency_token` changes it. Capture via a redefined `Registry::Service::Stripe::create_payment_intent`.

- [ ] **Step 2: Run it, verify it fails.**

- [ ] **Step 3: Implement.** On `Payment->create`, ensure `metadata.idempotency_token` exists (generate a UUID if absent). **Tricky spot:** `create` wraps metadata as `{ -json => ... }` before `SUPER::create` (Payment.pm:105-109) and `ADJUST` decodes it back on load — set the token on the metadata hash *before* the `-json` wrapping, and confirm it survives the decode round-trip on reload. In `create_payment_intent[_async]`, pass `_idempotency_key => "pi-create:" . $metadata->{idempotency_token}`. Add `method rotate_idempotency_token ($db)` that assigns a fresh token and persists it.

- [ ] **Step 4: Run it, verify pass.**
- [ ] **Step 5: Commit.** `git commit -am "Leg B: derive stable Stripe idempotency key from payment token"`

### Task B3: Workflow step reuses the run's payment row; retry rotates

- [ ] **Step 1: Write the failing test** (integration-style, mocked Stripe) in `t/dao/payment-idempotency.t`: driving the payment step twice with `agreeTerms` for one run creates exactly **one** payment row and calls `create_payment_intent` with the **same** idempotency key both times; a failure→retry path rotates the token (new key).

- [ ] **Step 2: Run it, verify it fails.**

- [ ] **Step 3: Implement** in `lib/Registry/DAO/WorkflowSteps/Payment.pm`:
  - In `create_payment`, if `$run->data->{payment_id}` already references a non-completed payment, reuse it (refresh amount/line items) instead of `Payment->create`ing a new row.
  - In `handle_payment_callback`'s decline/retry branch, call `$payment->rotate_idempotency_token($db)` before re-creating the intent so the retry is a genuinely new charge.

- [ ] **Step 4: Run it, verify pass.** Also run the existing `t/integration/tenant-paid-enrollment.t` to confirm no regression (`carton exec prove -lv t/integration/tenant-paid-enrollment.t`).
- [ ] **Step 5: Commit.** `git commit -am "Leg B: one payment row per run; retry rotates idempotency token"`

---

## Leg C — Perl real-Stripe suite (I1–I7)

**Depends on Leg A (I6), Leg B (I7), Leg 0 (recipe).**

**Files:**
- Create: `t/lib/Test/Registry/StripeConnect.pm` (on-the-fly test connected account from Leg 0's recipe; ready + not-ready variants)
- Create: `t/lib/Test/Registry/StripeConfirm.pm` (server-side confirm + retrieve charge)
- Create: `t/lib/Test/Registry/StripeWebhook.pm` (build + sign + POST a `payment_intent.succeeded` event; based on the `post_webhook` pattern in `t/controller/payment-intent-webhook.t`)
- Create: `t/stripe-live/paid-enrollment.t` (the gated suite)

### Task C1: `Test::Registry::StripeConnect` helper

- [ ] **Step 1:** Write the helper implementing Leg 0's validated recipe. Provide `->ready_account` (returns an `acct_...` that is `charges_enabled`) and `->unready_account`. Add a module-level guard: `plan skip_all` is the *caller's* job, but expose `Test::Registry::StripeConnect::available()` returning true only when `STRIPE_SECRET_KEY` (test) is set.
- [ ] **Step 2:** Add a tiny self-test `t/stripe-live/connect-helper.t` that `skip_all` unless `available()`, else asserts `ready_account` returns a `charges_enabled` account. Run with a test key locally.
- [ ] **Step 3: Commit.** `git commit -am "Leg C: Test::Registry::StripeConnect on-the-fly test account helper"`

### Task C2: `StripeConfirm` + `StripeWebhook` helpers

- [ ] **Step 1:** `StripeConfirm`: `confirm($payment_intent_id, $pm)` (default `pm_card_visa`) → confirmed intent; `charge_for($payment_intent_id)` → retrieved charge object.
- [ ] **Step 2:** `StripeWebhook`: `post_succeeded($t, $payment_id, $tenant_slug, $pi_id, %opts)` — build the event, sign with `$ENV{STRIPE_WEBHOOK_SECRET}` (HMAC-SHA256 of `"$ts.$payload"`), POST to `/webhooks/stripe`. Reuse the exact signing shape from `t/controller/payment-intent-webhook.t:69-78`.
- [ ] **Step 3: Commit.** `git commit -am "Leg C: StripeConfirm + StripeWebhook test helpers"`

### Task C3: The gated suite `t/stripe-live/paid-enrollment.t`

- [ ] **Step 1: Guard.** First lines: `plan skip_all => 'set STRIPE_SECRET_KEY (test) to run real-Stripe suite' unless $ENV{STRIPE_SECRET_KEY};` Set a known `local $ENV{STRIPE_WEBHOOK_SECRET}` for self-signing.
- [ ] **Step 2: Fixtures.** Provision a tenant + tenant-schema fixtures (parent, child, published paid session with a pricing plan) — reuse the pattern from `t/integration/tenant-paid-enrollment.t`. Set the tenant's `stripe_connect_account_id` to `StripeConnect->ready_account` and link the 2% plan (as that test does).
- [ ] **Step 3: I1+I2** — drive the payment step (real `create_payment_intent`), `StripeConfirm->confirm`, retrieve the charge, assert `transfer_data.destination`, `on_behalf_of`, and `application_fee_amount` == 2% of the fixture amount.
- [ ] **Step 4: I4** — `StripeWebhook->post_succeeded(...)` → 200 + exactly one enrollment; POST again → 200 (duplicate) + still one enrollment.
- [ ] **Step 5: I3** — a fresh payment confirmed with `pm_card_chargeDeclined`; assert the step returns an error/retry and no enrollment.
- [ ] **Step 6: I5** — a tenant using `StripeConnect->unready_account` (or `stripe_charges_enabled=false`); assert the gate blocks, no Stripe call, zero payment rows.
- [ ] **Step 7: I6** — refund the I1 charge; assert the real refund object reflects the plan's `refund_application_fee` policy at the cent level, and the transfer is reversed.
- [ ] **Step 8: I7** — submit the same enrollment twice (same idempotency token) → assert exactly one charge at Stripe: retrieve the PaymentIntent and confirm a single `latest_charge` (or one entry in `charges.data`), and that the two create calls returned the same intent id. A rotated retry produces a distinct intent id.
- [ ] **Step 9: Run with a real test key locally.** `STRIPE_SECRET_KEY=sk_test_... STRIPE_WEBHOOK_SECRET=whsec_local carton exec prove -lv t/stripe-live/paid-enrollment.t`. Expect all pass. Confirm the file `skip_all`s cleanly with the key unset.
- [ ] **Step 10: Commit.** `git commit -am "Leg C: real-Stripe test-mode suite proving I1-I7"`

---

## Leg D — CI workflow + Playwright smoke

**Depends on Leg C.**

**Files:**
- Create: `.github/workflows/stripe-e2e.yml`
- Create: `t/playwright/payment-smoke.spec.js`
- Create: `t/playwright/setup_payment_test_data.pl`

### Task D1: `stripe-e2e.yml`

- [ ] **Step 1:** Author the workflow modeled on `.github/workflows/playwright.yml`, with:
  - Triggers: `push` to `main`; `pull_request` (guarded so the Stripe steps run only when `github.event.pull_request.head.repo.full_name == github.repository`). **Do not** use `pull_request_target`.
  - `env:` pulls `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_WEBHOOK_SECRET` from `secrets`.
  - Two steps: `carton exec prove -lv t/stripe-live/` and `npx playwright test t/playwright/payment-smoke.spec.js --project=chromium`.
  - Non-blocking (informational).
- [ ] **Step 2:** Add the three repository secrets (document in the PR body that perigrin must set them; the workflow references them by name).
- [ ] **Step 3: Commit.** `git commit -am "Leg D: dedicated non-blocking stripe-e2e workflow"`

### Task D2: Playwright happy-path smoke

- [ ] **Step 1:** `setup_payment_test_data.pl` — extend the `setup_registration_test_data.pl` pattern to mark the tenant Connect-ready (via `Test::Registry::StripeConnect->ready_account`) and seed a paid session + parent + child + magic link. Emit JSON the spec consumes.
- [ ] **Step 2:** `payment-smoke.spec.js` — `test.skip(!process.env.STRIPE_SECRET_KEY)`. Log in via magic link, walk to the payment step, wait for `#payment-element` to mount, fill card `4242 4242 4242 4242`, submit, assert the complete page renders and (via `psql`, as `tenant-signup.spec.js` does) an enrollment row exists. Preserve the `&payment_intent_id=...` return-url contract.
- [ ] **Step 3: Run locally** with test keys + browsers installed; then confirm it `test.skip`s without keys.
- [ ] **Step 4: Commit.** `git commit -am "Leg D: Playwright payment happy-path smoke + setup script"`

---

## Leg E — Doc reconciliation (independent)

**Files:**
- Modify: `docs/operations/sacp-stripe-connect-onboarding.md`

- [ ] **Step 1:** Fix the stale `2.5%` at `docs/operations/sacp-stripe-connect-onboarding.md:156` to `2%` (the implemented launch rate), or better, phrase it as "the tenant's plan rate (2% at launch)".
- [ ] **Step 2:** Add a short subsection documenting the `refund_application_fee` plan config (default true) and the charge-creation idempotency key.
- [ ] **Step 3:** Add a runbook step pointing at the gated `stripe-e2e` suite for pre-launch validation.
- [ ] **Step 4: Commit.** `git commit -am "Leg E: reconcile onboarding runbook (2% rate, refund config, idempotency, test suite)"`

---

## Definition of done

- Legs A & B: mocked unit/integration tests green; full `carton exec prove -lr t/` stays 100% green with no Stripe key.
- Leg C: `t/stripe-live/paid-enrollment.t` passes I1–I7 against Stripe test mode; `skip_all`s cleanly without a key.
- Leg D: `stripe-e2e.yml` runs the gated suites where secrets exist; the smoke confirms one real test card and lands a real enrollment; both self-skip otherwise.
- Leg E: runbook reflects 2%, the refund config, the idempotency key, and the test suite.
- Follow-ups from the spec (real webhook wire format, concurrent return-vs-webhook race, currency, fee-sanity clamp, refund-amount clamp) filed as issues.
