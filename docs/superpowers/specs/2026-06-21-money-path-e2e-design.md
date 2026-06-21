# Money-path E2E: "ready to take money" — design

Date: 2026-06-21
Status: Approved (brainstorm)
Author: perigrin (with Claude)

## Problem

Registry is about to switch on real payments. The money path is **parent pays
tuition for a program**: a Stripe Connect destination charge that settles into
the tenant's connected account while the platform keeps an application fee
derived from the tenant's pricing plan (#267). The flow is:

1. Parent agrees to terms on the enrollment payment step.
2. `Registry::DAO::Payment->create_payment_intent` builds a PaymentIntent with
   destination-charge params (`transfer_data[destination]`, `on_behalf_of`,
   `application_fee_amount` = the plan rate via
   `Registry::PriceOps::RevenueShare`).
3. Parent confirms the card (Stripe Elements, client-side).
4. `payment_intent.succeeded` webhook (and the parent-return callback)
   idempotently finalize enrollment and queue the confirmation email.

Nothing today exercises this against real Stripe. The Playwright job runs with
no Stripe key (`.github/workflows/playwright.yml`), and every Perl test mocks
the Stripe service. `t/integration/tenant-paid-enrollment.t` redefines
`Registry::Service::Stripe::create_payment_intent` to return a fake intent,
asserts the params we *would* send, then hand-synthesizes the webhook event and
calls `_process_payment_intent_succeeded` directly. That proves our construction
and finalization *logic*. It does not prove Stripe accepts those params, routes
to the connected account, honors the fee, or that the signed webhook path works.

We have no end-to-end proof the money path works.

### Two Stripe paths — only one is in scope

- **Tenant signup → subscription** (`WorkflowSteps/TenantPayment.pm`): the tenant
  subscribing to a Registry platform plan (SetupIntent + Subscription). Home of
  the `seti_test` mock and the no-key bypass. **Out of scope.**
- **Parent → program enrollment** (`Payment.pm`, `WorkflowSteps/Payment.pm`,
  `Controller/Webhooks.pm`): the destination-charge revenue-share path from #267.
  **This is the money path.** Everything below is about this path.

## Goal

Prove, against **real Stripe test mode**, the invariants that constitute "ready
to take money," and make the platform's refund behavior configurable per pricing
plan.

## Invariants to prove

| # | Invariant | Layer |
|---|---|---|
| I1 | A paid enrollment routes to the tenant's connected account and succeeds | Perl + Playwright |
| I2 | `application_fee_amount` on the **real charge object** equals the tenant's plan rate | Perl |
| I3 | A declined card fails cleanly and offers retry | Perl |
| I4 | The **real signed** `payment_intent.succeeded` webhook finalizes enrollment, and a replay is deduped (exactly one enrollment) | Perl |
| I5 | A Connect-not-ready tenant never reaches Stripe (defense-in-depth at the real boundary) | Perl |
| I6 | A refund succeeds, reverses the transfer, and honors the plan's application-fee policy | Perl |

### Explicitly out of scope

- 0%-fee Free-plan tenant charge. The plan-driven fee math at the 0 boundary is
  already unit-tested; a real charge adds cost, not confidence.
- Pure-logic gate coverage. The readiness gate's logic stays proven by the
  existing mocked `tenant-paid-enrollment.t`. I5 is the real-boundary echo, not a
  replacement.

## Architecture — two layers

### Layer 1: Perl real-Stripe suite (new, gated) — owns I1–I6

Drives the real test-mode Stripe API server-side. No browser, no tunnel, no
Stripe-side webhook configuration.

Per scenario:

1. Create the PaymentIntent through the real `Payment->create_payment_intent`
   with destination-charge params.
2. Confirm server-side with a Stripe test payment method
   (`pm_card_visa` for success, `pm_card_chargeDeclined` for I3).
3. Retrieve the resulting charge from Stripe and assert routing
   (`transfer_data.destination`, `on_behalf_of`) and the plan-driven
   `application_fee_amount` (I1, I2).
4. Build a `payment_intent.succeeded` event from the real charge data, sign it
   with the known test `STRIPE_WEBHOOK_SECRET`, and POST it to
   `/webhooks/stripe`. This exercises the real signature verification, the
   `webhook_events` dedup claim, and `finalize_enrollment` (I4). POST it twice to
   prove dedup (exactly one enrollment).
5. For I5, drive the payment step with a deliberately-unready connected account
   and assert no Stripe call is made and zero payment rows are written.
6. For I6, refund the succeeded charge and assert the real refund object reflects
   the plan's `refund_application_fee` policy.

Why server-side confirmation is sufficient: the money invariants (routing, fee on
the real charge, signed webhook, idempotency, declined, refund) are all
server-side. Stripe accepts confirming a PaymentIntent with a test payment-method
token directly via the API, so no browser is required to produce a real charge.

Why self-signed webhooks: because the suite builds and signs the event itself
from real charge data and POSTs it to our own endpoint, `STRIPE_WEBHOOK_SECRET`
only needs to be a known value we sign with. It does not need to match any
Stripe-registered endpoint. This removes the need for a public URL, a tunnel, or
`stripe listen` in CI, and makes the test deterministic. The real-API dependency
is confined to the charge/refund calls.

### Layer 2: Playwright smoke (new, gated) — one happy-path UI proof

`t/playwright/payment-smoke.spec.js` proves the browser confirmation path works
with a real publishable key:

1. Seed a Connect-ready tenant, a published paid session, and a parent + child;
   log in via magic link.
2. Walk the summer-camp-registration workflow to the payment step.
3. The Stripe Payment Element mounts with the real `pk_test` key; type test card
   `4242 4242 4242 4242`; `confirmPayment` succeeds.
4. The `return_url` round-trips to `handle_payment_callback`, which finalizes
   enrollment synchronously (the parent-return path retrieves the real intent and
   calls `finalize_enrollment`). Assert the complete page renders and an
   enrollment row exists.

Because the parent-return path finalizes synchronously, the smoke asserts a real
enrollment **without** needing Stripe to deliver a webhook to CI. All edge cases
(declined, refund, signed-webhook replay, gate) live in the Perl suite, not here.

## Test helpers (`t/lib/`)

Test-only infrastructure lives in `t/lib/`, never in production classes.

1. `Test::Registry::StripeConnect` — create a fresh Stripe **test** connected
   account and bring it to `charges_enabled` (request `card_payments` +
   `transfers` capabilities, accept ToS, attach a test external account). Provide
   a deliberately-unready variant for I5. The exact account-provisioning recipe
   is validated with the Stripe MCP during build. Created on-the-fly per run:
   hermetic, self-healing, no shared mutable state.
2. `Test::Registry::StripeConfirm` — confirm a PaymentIntent server-side with a
   given test payment method; retrieve the resulting charge.
3. `Test::Registry::StripeWebhook` — given real charge/PI data, build a
   `payment_intent.succeeded` payload and a valid `stripe-signature` header from
   the known test `STRIPE_WEBHOOK_SECRET`, and POST it to the app.

## Refund as a pricing-plan configuration

The revenue-share *rate* already lives in `pricing_plans.pricing_configuration`.
Refund behavior becomes symmetric.

- **New plan config key** `refund_application_fee` (boolean) in
  `pricing_configuration`.
- **New resolver** `Registry::PriceOps::RevenueShare::refund_application_fee_for_tenant($db, $slug)`,
  mirroring `revenue_share_fraction_for_tenant`: linked plan → its setting;
  NULL/absent FK → the platform-default plan's setting. Same fail-loud behavior as
  the fraction resolver.
- **Default `true`** when a plan does not set the key: a refund returns the full
  amount to the parent, including the platform's cut, unless a plan opts out.
  This is an *effective behavior change* — today's `Payment->refund` never refunds
  the fee. The seeded platform-default and tenant plans get the key set
  explicitly so the intended behavior is visible, not implicit.
- **`Payment->refund` / `refund_async` extended**: for tenant (destination-charge)
  payments — detected by `tenant_slug` in metadata, the same signal
  `_connect_params` uses — always pass `reverse_transfer => true` (the tenant
  returns the tuition it received) and pass `refund_application_fee => <policy>`
  from the resolver. Registry/platform payments (no `tenant_slug`) are unchanged.
  Stripe prorates the fee refund on partial refunds automatically.

## CI wiring — `stripe-e2e.yml` (dedicated, non-blocking)

- Triggers: `push` to `main`, and `pull_request` from **same-repo** branches only
  (guard on `github.event.pull_request.head.repo.full_name == github.repository`
  because fork PRs do not receive secrets).
- Secrets: `STRIPE_SECRET_KEY` (`sk_test_`), `STRIPE_PUBLISHABLE_KEY`
  (`pk_test_`), `STRIPE_WEBHOOK_SECRET` (a known test value we sign with).
- Gating: both the Perl suite and the Playwright smoke skip
  (`plan skip_all` / `test.skip`) when `STRIPE_SECRET_KEY` is absent, so local
  `prove -lr t/` and fork PRs stay 100% green. The existing live-key guard in
  `Payment.pm` aborts on an `sk_live_` key outside production by design.
- Non-blocking, matching the existing Playwright-job precedent.

## What stays unchanged

The existing mocked tests keep running in the fast suite as-is:
`t/integration/tenant-paid-enrollment.t`, the Alex
`t/user-journeys/alex/02-activate-and-collect.t`, and
`t/playwright/camp-registration.spec.js`. This work **adds** a real-money proof
layer; it does not remove logic coverage or any mock.

## Build sequencing (subagent-driven TDD, two-stage review per leg)

Each leg is independently shippable; perigrin merges all PRs.

- **Leg A — Refund-as-plan-config feature.** Resolver
  (`refund_application_fee_for_tenant`) + `Payment->refund`/`refund_async`
  changes + seed-plan key + unit tests (mocked). No Stripe key required.
- **Leg B — Perl real-Stripe suite.** The three `t/lib/` helpers + the gated
  suite proving I1–I6. Validate the connected-account recipe with the Stripe MCP
  first.
- **Leg C — CI + browser smoke.** `stripe-e2e.yml`, `payment-smoke.spec.js`, and
  `setup_payment_test_data.pl`.
- **Leg D — Doc reconciliation.** Fix the stale `2.5%` in
  `docs/operations/sacp-stripe-connect-onboarding.md` (implementation is 2%),
  document the refund-fee config, and add a runbook step for the test suite.

## Risks and open questions

- **Connected-account provisioning recipe.** Bringing a test connected account to
  `charges_enabled` purely via the API can be fiddly (capabilities, ToS, external
  account). Validate with the Stripe MCP before building Leg B; this is the main
  feasibility risk.
- **Default `refund_application_fee = true`** changes effective refund behavior
  for unconfigured plans. Mitigated by setting the key explicitly on seeded
  plans.
- **Stripe API latency/flakiness** in the gated suite. Contained by keeping the
  job non-blocking and the suite small.

## Success criteria

- The Perl real-Stripe suite passes I1–I6 against Stripe test mode in CI.
- The Playwright smoke confirms one real test card and lands a real enrollment.
- Local `prove -lr t/` and fork PRs remain 100% green (suites self-skip without
  keys).
- Refund behavior is plan-configurable and the seeded plans declare it
  explicitly.
- The onboarding runbook reflects the real launch fee (2%) and the refund-fee
  config.
