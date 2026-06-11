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
end-to-end at the HTTP layer. A regression in any of these breaks Alex's business, not a
feature.

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

## Design

### Leg 1 — `t/user-journeys/alex/01-acquire-tenant.t`
*Outcome: the signup funnel produces a working, billable tenant.*

Drive the real `tenant-signup` workflow over HTTP the way Morgan's leg drives
`project-creation`: POST the workflow start URL, follow each step's redirect, submit each
form (organization profile → team setup → pricing plan selection → payment → review →
complete). The `TenantPayment` step is satisfied through its existing test-mode
`setup_intent` seam (`seti_test…`, supported in production code — no mock mode added).
Outcome assertions, in Alex's terms:

1. The tenant row and schema exist; `clone_schema` artifacts are present (workflows count
   > 0 in the tenant schema).
2. The team users created during signup exist and are dual-resident (registry + tenant).
3. The new tenant's storefront responds: GET `/` with the tenant's host header renders the
   tenant-storefront workflow page (200, tenant name visible).

This is the first end-to-end HTTP walk of the funnel; the workflow steps are currently
only unit-tested. Failures here are findings (fix or file), never assertions to weaken.

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
3. **Collect:** the parent retries over HTTP → enrollment proceeds; the captured
   PaymentIntent params carry `transfer_data[destination]`, `on_behalf_of`, and
   `application_fee_amount == Registry::DAO::Payment::application_fee_cents(_to_cents($plan_amount))`;
   the payment row lands in the tenant schema.

Distinct from `t/integration/tenant-paid-enrollment.t` by driving the enrollment workflow
through the HTTP surface rather than calling step classes directly.

### Leg 3 — `t/user-journeys/alex/03-platform-billing.t`
*Outcome: Registry bills the tenant for the platform subscription.*

Walk the pricing-plan-selection + `TenantPayment` portion of signup (HTTP, as in Leg 1, or
the narrowest HTTP path that reaches it) and assert the platform-side artifacts:

1. A `PricingRelationship` (and related platform-billing rows) exists in the registry
   schema linking tenant and plan.
2. The tenant row's `billing_status` reflects the established subscription/trial state.
3. The Solo-tier copy shown to the signing-up owner derives from
   `Registry::DAO::Payment::REVENUE_SHARE_PERCENT` (single source of truth).

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
   either sweep — failure is isolated and logged.
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
