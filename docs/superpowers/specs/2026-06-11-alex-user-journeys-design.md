# Alex User Journeys — Design

ABOUTME: Defines the platform-owner (Alex) user-journey test suite: four business-outcome
ABOUTME: legs under t/user-journeys/alex/ following the existing persona-journey conventions.

- Status: Draft (pending review)
- Date: 2026-06-11
- Persona: `docs/personas/alex.md` (Registry solo founder — platform owner/operator)
- Pattern: `t/user-journeys/{morgan,nancy,jordan,amara}/` — numbered legs, real HTTP over
  `Test::Registry::Mojo`, own `Test::Registry::DB` per file, DAO-level outcome assertions.

## Problem

Every persona with in-app flows has journey tests except Alex — yet Alex's stake is the
largest: the platform must acquire, activate, and bill customers, and run itself while he
is away. Those guarantees exist today only as scattered unit/integration tests; nothing
walks them as user-visible stories, and the tenant-signup funnel has never been driven
end-to-end at the HTTP layer (`t/controller/tenant-signup-data-flow.t` walks
landing→review; the payment→complete segment has never been walked over HTTP). A
regression in any of these breaks Alex's business, not a feature.

## Decisions (settled with the requester)

- **Frame:** Alex journeys are **business outcomes** he depends on, not hands-on-keyboard
  flows. Other personas may be the on-screen actors inside them (Jordan signs up; Nancy
  enrolls) — each leg's ABOUTME names the outcome from `alex.md` it protects.
- **Coverage:** all four outcomes — acquire, activate+collect, platform billing, platform
  health.
- **Overlap policy:** narrative re-walk via HTTP. Journeys assert the user-visible path even
  where integration tests cover internals (`t/integration/tenant-paid-enrollment.t`,
  `t/job/*`). Runtime cost accepted.
- **Structure:** four numbered legs, one per outcome, each self-contained with its own test
  DB (option A; matches the existing per-leg convention).
- **Implementation sequencing (pushback resolution):** build the cheap legs first —
  4 (health) → 2 (activate+collect) → 3 (billing) → 1 (acquire) — so the suite delivers
  value even if Leg 1 stalls on funnel findings. Leg 1 may land in two stages: a
  walk-the-funnel commit (drive every step, assert HTTP-level success/redirects only),
  then an outcome-assertions commit, with funnel bugs fixed or filed between them.
- **Funnel friction inventory (pushback resolution):** while walking the funnel with
  minimal data, Legs 1 and 3 record which fields each signup step marks required vs.
  accepts empty, and which of those downstream steps actually consume. The inventory is
  filed as a funnel-friction issue (per-field evidence); removing fields is a separate
  product change decided field-by-field — NOT part of this suite. The legs keep asserting
  the minimal-data path works, permanently guarding against required-field creep.

## Design

### Leg 1 — `t/user-journeys/alex/01-acquire-tenant.t`
*Outcome: the signup funnel produces a working, billable tenant.*

Drive the real `tenant-signup` workflow over HTTP the way Morgan's leg drives
`project-creation`: POST the workflow start URL, follow each step's redirect, submit each
form. The funnel's actual step order (per `workflows/tenant-signup.yml`) is
landing → organization profile → team setup (users) → pricing plan selection → **review →
payment** → complete. The `TenantPayment` step is satisfied through its existing test-mode
`setup_intent` seam (`seti_test…`, supported in production code — no mock mode added).
Note: `TenantPayment` `warn`s a "Would send invitation email" line per `invite_pending`
team member — the leg either keeps the team admin-only or captures those warns so output
stays pristine. Outcome assertions, in Alex's terms:

1. The tenant row and schema exist; `clone_schema` artifacts are present (workflows count
   > 0 in the tenant schema).
2. The team users created during signup exist and are dual-resident (registry + tenant).
3. The new tenant's storefront responds: GET `/` with the tenant's host header renders the
   tenant-storefront workflow page (200, tenant name visible).

This is the first end-to-end HTTP walk of the funnel; the payment→complete steps are
currently only unit-tested (landing→review has HTTP coverage in
`t/controller/tenant-signup-data-flow.t`). Failures here are findings (fix or file),
never assertions to weaken.

### Leg 2 — `t/user-journeys/alex/02-activate-and-collect.t`
*Outcome: activating a tenant's Stripe Connect account unlocks paid enrollment, and the
platform's 2.5% is collected at charge time.*

Fixtures: a provisioned tenant with a paid session/pricing plan, a parent + child (the
readiness-gate test's fixture approach), Stripe intercepted at the
`Registry::Service::Stripe` seam with `local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy'`.

1. **Gated:** the parent attempts paid enrollment through the registration workflow over
   HTTP → the readiness gate refuses with the friendly message; no payment row in either
   schema.
2. **Activate:** Alex records the connected account (tenant-row update mirroring the
   runbook), then an `account.updated` webhook event flips/confirms
   `stripe_charges_enabled`/`stripe_details_submitted` — both activation paths exercised.
   The webhook is delivered **over HTTP with a real signed payload** (set
   `STRIPE_WEBHOOK_SECRET`, compute the `stripe-signature` HMAC the way
   `_verify_stripe_signature` expects) — consistent with the suite's over-HTTP ethos,
   rather than the direct `_process_account_updated` call idiom used in
   `t/controller/webhook-tenant-payment-finalization.t`.
3. **Collect:** the parent retries over HTTP → enrollment proceeds; the captured
   PaymentIntent params carry `transfer_data[destination]`, `on_behalf_of`, and
   `application_fee_amount == Registry::DAO::Payment::application_fee_cents(_to_cents($plan_amount))`;
   the payment row lands in the tenant schema.
4. **Complete (pushback resolution):** deliver a signed `payment_intent.succeeded` over
   HTTP (synthesized from the captured intent params — the same proof shape as the
   integration test; reuse the signing helper from step 2) → the payment is `completed`
   and the enrollment exists, both in the tenant schema. The leg now walks Alex's outcome
   end to end: gated → activated → charged → enrolled.

Distinct from `t/integration/tenant-paid-enrollment.t` by driving the enrollment workflow
and both webhooks through the HTTP surface rather than calling step classes/handler
methods directly.

### Leg 3 — `t/user-journeys/alex/03-platform-billing.t`
*Outcome: Registry bills the tenant for the platform subscription.*

Start a `tenant-signup` run over HTTP and drive it from the start with **minimal form
data** at each pre-pricing step (the data-flow test proves those steps accept minimal
input) — no mid-workflow entry tricks; journey tests walk the path real users take. The
walk shape intentionally mirrors Leg 1 with different assertions; if the two legs'
fixture setup converges, share a `t/lib/` helper per the YAGNI rule. Then assert the
platform-side artifacts **that actually exist post-signup** (verified against the code: signup does NOT create a
tenant↔plan `PricingRelationship` — `PricingPlanSelection` only finds the pre-seeded
platform plans and stashes the choice in run data; `TenantPayment::_provision_tenant`
writes billing fields onto the tenant row):

1. The selected plan is recorded in the workflow run data (`selected_pricing_plan`), and
   the provisioned tenant row carries the billing fields: `stripe_subscription_id`,
   `billing_status` (`trial` on the `seti_test` path), `trial_ends_at`.
2. **Known gap, asserted deliberately:** no platform-billing row links the tenant to its
   chosen plan after signup. The leg documents this with a comment; if a tenant↔plan
   record is later introduced, the assertion gets strengthened. (Fix-or-file policy: if
   the implementer or reviewers judge this a product bug, file it — do not build the
   missing feature inside a journey test.)
3. **Pricing-copy drift detection:** the plan copy shown to the signing-up owner must
   agree with what the platform actually charges
   (`Registry::DAO::Payment::REVENUE_SHARE_PERCENT` = 2.5). **This is expected to FAIL
   today**: the seeded platform plan is "Registry Revenue Share - 2%" with `amount 0.02`
   (`sql/deploy/unified-pricing-infrastructure.sql:107-113`), while destination charges
   collect 2.5% — a real, pre-existing drift between displayed price and collected fee.
   Per the failure philosophy this is a finding: fix the seeded data (and any
   `pricing_configuration` template copy) to 2.5% in-branch if the requester confirms
   2.5% is the decided rate, or file an issue and mark the assertion TODO with the issue
   reference.

**Explicit non-goal (stated in the file):** recurring usage-based billing — the
`_get_usage_data` branch is deliberately non-functional pending redesign (issue #263).
The leg asserts the subscription is *established*, not that monthly invoices flow.

### Leg 4 — `t/user-journeys/alex/04-platform-health.t`
*Outcome: the automation runs without Alex.*

Thin aggregation leg, deliberately:

1. Two provisioned tenants, one with sweepable waitlist state (offered entry with past
   `expires_at`; cancelled enrollment with waiting entry). Run the no-arg
   `ProcessWaitlist`/`WaitlistExpiration` performs (the `t/job/*-tenant.t` harness idiom)
   and assert per-tenant processing reached the tenant with state and did not abort on the
   other.
2. A `registry.tenants` row whose schema does not exist (the #265 shape) does not abort
   either sweep — failure is isolated and logged. **Framing (pushback resolution):** this
   is a defense-in-depth assertion, not an endorsement of that state. The sweep must never
   let one bad row break other tenants regardless of whether such rows turn out to be
   legal; the test comment links #265, and the assertion survives any resolution of it
   (including deleting the row and forbidding the state).
3. GET `/health` returns 200 with `db: ok`.

### Shared conventions (all legs)

- Own `Test::Registry::DB` + `Test::Registry::Mojo` per file; workflows imported from YAML
  (`Workflow->from_yaml`, skipping drafts) where the leg uses workflows.
- Helpers from `Test::Registry::Helpers` (`workflow_url`, `workflow_run_step_url`, …).
- Stripe never hits the network: `Service::Stripe` seam interception + `sk_test_dummy`;
  the live-key guard stays effective.
- `$$`-suffixed identities; pristine output; cleanup via `cleanup_test_database`.
- No test infrastructure in production code. Shared fixture helpers go to `t/lib/` only if
  two or more legs genuinely duplicate them (YAGNI otherwise).

## Error handling / failure philosophy

Journey legs assert outcomes, not implementations. When a leg fails:
- If the user-visible flow is broken, that is a product bug — fix it or file it.
- Never weaken an assertion or add a TODO to make a journey green without an issue
  reference.

## Testing strategy

The suite IS tests; its own verification is: each leg green and pristine standalone
(`carton exec prove -lv t/user-journeys/alex/<leg>.t` after
`carton exec ./registry workflow import registry` where needed), the whole persona suite
green (`carton exec prove -lr t/user-journeys/`), and the full suite still 100%
(`carton exec prove -lr t/`). Leg 1 is expected to surface real funnel bugs on first
run — budget for fix-or-file work there.

## Non-goals

- Self-service Connect onboarding UI (deferred epic) — Leg 2 activates via the tenant row
  + `account.updated`, the supported mechanisms today.
- Recurring usage billing (#263).
- Playwright/browser coverage — these are server-side journey tests like the rest of
  `t/user-journeys/`; the Playwright E2E suite is a separate concern.
- New journeys for Kylie & Rob (students) — out of scope here.

## Risks

| Risk | Mitigation |
| --- | --- |
| Leg 1 surfaces real funnel bugs (first HTTP walk) | Treat as findings: fix small/obvious in-branch, file issues otherwise; never weaken assertions. |
| Runtime growth (~4 extra DB provisions) | Accepted by decision; legs stay narrative-thin, no gratuitous fixtures. |
| Duplication drift with integration tests | Legs assert outcomes at the HTTP surface only; internals stay in the integration/unit suites. |
| `tenant-signup` requires registry-context host routing | Legs set the Host header / tenant resolution explicitly the way existing controller tests do; the registry-vs-tenant context per request is part of what's being tested. |
