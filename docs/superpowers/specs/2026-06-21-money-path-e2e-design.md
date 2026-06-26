# Money-path E2E: "ready to take money" — design

Date: 2026-06-21 (revised 2026-06-26 after spec review + adversarial pushback)
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
to take money"; close the idempotent-charge gap; and make the platform's refund
behavior configurable per pricing plan.

## Invariants to prove

| # | Invariant | Layer |
|---|---|---|
| I1 | A paid enrollment routes to the tenant's connected account and succeeds | Perl + Playwright |
| I2 | `application_fee_amount` on the **real charge object** equals the tenant's plan rate | Perl |
| I3 | A declined card fails cleanly and offers retry | Perl |
| I4 | A signed `payment_intent.succeeded` webhook finalizes enrollment, and a replay is deduped (exactly one enrollment) | Perl |
| I5 | A Connect-not-ready tenant never reaches Stripe (defense-in-depth at the real boundary) | Perl |
| I6 | A refund succeeds, reverses the transfer, and honors the plan's application-fee policy | Perl |
| I7 | A double-submitted / retried enrollment creates **at most one charge** (idempotent charge creation) | Perl + unit |

### I4 scope and honesty (what self-signing does and does not prove)

I4 builds the event from real charge data and signs it with the known test
`STRIPE_WEBHOOK_SECRET`. Because our signer and our verifier
(`Webhooks::_verify_stripe_signature`) use the same HMAC-SHA256 `t.payload`
scheme, I4 proves the **dedup + finalize path and our own HMAC round-trip** — it
does **not** prove our parser accepts Stripe's real wire format (Stripe's header
can carry multiple `v1` values, a `v0`, ordering quirks; our parser takes the
first `v1`+`t` only). Proving the real wire format needs one genuinely
Stripe-delivered event (`stripe listen`/CLI), which this design deliberately
excludes to stay deterministic. **This is a named limitation** (see Follow-ups),
not a claim I4 covers.

### I5 / I6 assertion granularity (pinned)

- **I5** drives the payment step with a tenant whose `stripe_connect_ready` is
  false (e.g. `stripe_charges_enabled = false`) — the boundary the gate in
  `WorkflowSteps/Payment.pm` actually checks. Assert: no Stripe call, zero
  payment rows.
- **I6** asserts at the **cent level on the real refund object** retrieved from
  Stripe (e.g. the application-fee amount actually refunded), not merely that a
  param was passed.

### Explicitly out of scope

- 0%-fee Free-plan tenant charge. The plan-driven fee math at the 0 boundary is
  already unit-tested; a real charge adds cost, not confidence.
- Pure-logic gate coverage. The readiness gate's logic stays proven by the
  existing mocked `tenant-paid-enrollment.t`. I5 is the real-boundary echo, not a
  replacement.

## Architecture — two layers

### Layer 1: Perl real-Stripe suite (new, gated) — owns I1–I7

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
   `/webhooks/stripe`. Exercises the dedup claim and `finalize_enrollment` (I4).
   POST twice to prove dedup (exactly one enrollment).
5. For I5, drive the payment step with a not-ready tenant and assert no Stripe
   call is made and zero payment rows are written.
6. For I6, refund the succeeded charge and assert the real refund object reflects
   the plan's `refund_application_fee` policy at the cent level.
7. For I7, submit the same logical enrollment twice (and exercise the retry
   path) and assert at most one charge results.

Why server-side confirmation is sufficient: the money invariants (routing, fee,
signed webhook, idempotency, declined, refund) are all server-side. Stripe
accepts confirming a PaymentIntent with a test payment-method token directly via
the API, so no browser is required to produce a real charge.

### Layer 2: Playwright smoke (new, gated) — one happy-path UI proof

`t/playwright/payment-smoke.spec.js` proves the browser confirmation path works
with a real publishable key:

1. Seed a Connect-ready tenant, a published paid session, and a parent + child;
   log in via magic link.
2. Walk the summer-camp-registration workflow to the payment step.
3. The Stripe Payment Element mounts with the real `pk_test` key; type test card
   `4242 4242 4242 4242`; `confirmPayment` succeeds.
4. The `return_url` round-trips to `handle_payment_callback` (the smoke must
   preserve the template's `&payment_intent_id=...` query-param contract), which
   finalizes enrollment synchronously. Assert the complete page renders and an
   enrollment row exists.

Because the parent-return path finalizes synchronously, the smoke asserts a real
enrollment **without** needing Stripe to deliver a webhook to CI. All edge cases
live in the Perl suite, not here.

## Test helpers (`t/lib/`)

Test-only infrastructure lives in `t/lib/`, never in production classes.

1. `Test::Registry::StripeConnect` — create a fresh Stripe **test** connected
   account and bring it to `charges_enabled`. **Account type: Custom / controller
   account** — a platform cannot drive a *Standard* account to `charges_enabled`
   via API, and production uses Standard per the runbook, but our
   destination-charge params (`transfer_data[destination]`, `on_behalf_of`,
   `application_fee_amount`) are account-type-agnostic, so a Custom test account
   exercises the same code. The recipe must request `card_payments` + `transfers`
   capabilities, accept ToS, attach a test external account, and **poll until the
   capabilities are `active` / `charges_enabled` is true** (capabilities pass
   through `requested → pending → active`; "requested" is not "active"). Provide a
   deliberately not-ready variant for I5. Created on-the-fly per run: hermetic,
   self-healing, no shared mutable state.
2. `Test::Registry::StripeConfirm` — confirm a PaymentIntent server-side with a
   given test payment method; retrieve the resulting charge.
3. `Test::Registry::StripeWebhook` — given real charge/PI data, build a
   `payment_intent.succeeded` payload and a valid `stripe-signature` header from
   the known test `STRIPE_WEBHOOK_SECRET`, and POST it to the app.

## Idempotent charge creation (I7 feature)

Today neither `create_payment_intent` nor `Registry::Service::Stripe` sends a
Stripe `Idempotency-Key`, and the retry path in `handle_payment_callback`
re-creates intents. A double-submit or network retry can produce multiple real
charges; the webhook dedup is event-level, not intent-level, so it does not catch
this.

- **`Registry::Service::Stripe` gains optional `Idempotency-Key` support** on
  charge-creating requests (an HTTP header on the POST).
- **The key is derived from a stable per-attempt identifier** so a duplicate
  submission of the *same* attempt dedups at Stripe (returning the original
  intent), while a deliberate retry-with-a-different-card is a *new* attempt with
  a new key. The exact key derivation and whether to also stop creating duplicate
  Payment rows per workflow run (`create_payment` creates a new Payment row on
  every `agreeTerms` POST) is a **plan-level design decision** — both the Stripe
  idempotency key and the per-run Payment-row reuse may be needed to fully close
  double-submit. The plan resolves this; the spec fixes the invariant (at most
  one charge) and the direction.
- Unit tests (mocked) assert the same key is sent for a duplicate of one attempt
  and a distinct key for a genuine retry; I7 in Layer 1 proves at-most-one-charge
  against real Stripe.

## Refund as a pricing-plan configuration (Leg A)

Kept in scope: operators issue refunds manually via `Payment->refund` today (no
UI/route calls it), so the fee policy should be correct now. The revenue-share
*rate* already lives in `pricing_plans.pricing_configuration`; refund behavior
becomes symmetric.

- **New plan config key** `refund_application_fee` (boolean) in
  `pricing_configuration`.
- **New resolver** `Registry::PriceOps::RevenueShare::refund_application_fee_for_tenant($db, $slug)`,
  mirroring `revenue_share_fraction_for_tenant`: linked plan → its setting;
  NULL/absent FK → the platform-default plan's setting. Same fail-loud behavior.
- **Default `true`** when a plan does not set the key: a refund returns the full
  amount to the parent, including the platform's cut, unless a plan opts out.
  This is an *effective behavior change* — today's `Payment->refund` never refunds
  the fee. The seeded platform-default and tenant plans get the key set
  explicitly (values pinned in the plan) so the intended behavior is visible.
- **`Payment->refund` / `refund_async` extended**: for tenant
  (destination-charge) payments — detected by `tenant_slug` in metadata, the same
  signal `_connect_params` uses — always pass `reverse_transfer => true` (the
  tenant returns the tuition it received) and `refund_application_fee => <policy>`
  from the resolver. Registry/platform payments (no `tenant_slug`) are unchanged.
  Partial-refund transfer-reversal and fee proportions are Stripe-managed; the
  implementer must not hand-roll proration. I6 pins the cent-level result.

## CI wiring — `stripe-e2e.yml` (dedicated, non-blocking)

- Triggers: `push` to `main`, and `pull_request` from **same-repo** branches only
  (guard on `github.event.pull_request.head.repo.full_name == github.repository`
  because fork PRs do not receive secrets).
- **Never use `pull_request_target`**, and never check out + execute PR-head code
  with the secret in scope. (The fork guard is necessary, not sufficient; this
  rule closes the real exfiltration vector.)
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
layer and two small money-path fixes; it does not remove logic coverage or any
mock.

## Build sequencing (subagent-driven TDD, two-stage review per leg)

These legs are a **sequence, not independent PRs** — there are real ordering
edges. perigrin merges each PR.

- **Leg 0 — Feasibility spike (before planning the rest).** Validate the
  Custom-connected-account → `charges_enabled` recipe with the Stripe MCP. If a
  test account cannot be driven to `charges_enabled` server-side, the "no
  browser/no tunnel" premise for Layer 1 must be revisited. This de-risks the
  core assumption *before* committing the plan.
- **Leg A — Refund-as-plan-config.** Resolver + `Payment->refund`/`refund_async`
  changes + seed-plan keys + unit tests (mocked). No Stripe key required.
- **Leg B — Idempotent charge creation (I7 feature).** `Idempotency-Key` support
  + key derivation + (if needed) per-run Payment-row reuse + unit tests (mocked).
  No Stripe key required. Independent of Leg A.
- **Leg C — Perl real-Stripe suite.** The three `t/lib/` helpers + the gated
  suite proving I1–I7. **Depends on Leg A (I6) and Leg B (I7)** and on Leg 0's
  validated recipe.
- **Leg D — CI + browser smoke.** `stripe-e2e.yml`, `payment-smoke.spec.js`,
  `setup_payment_test_data.pl`. **Depends on Leg C** (reuses the Connect helper).
- **Leg E — Doc reconciliation.** Fix the stale `2.5%` in
  `docs/operations/sacp-stripe-connect-onboarding.md` (implementation is 2%),
  document the refund-fee config + the idempotency key, and add a runbook step
  for the test suite. The 2.5%→2% fix depends on nothing and can land anytime.

Dependency DAG: `Leg 0 → {A, B} → C → D`; `E` (doc fix) is independent.

## Risks and open questions

- **Connected-account provisioning recipe (top risk).** Bringing a Custom test
  account to `charges_enabled` via API (capabilities reaching `active`, ToS,
  external account, `requirements.currently_due`) is the main feasibility
  unknown. Leg 0 validates it before the plan is finalized.
- **Default `refund_application_fee = true`** changes effective refund behavior
  for unconfigured plans. Mitigated by setting the key explicitly on seeded plans.
- **Stripe API latency/flakiness** in the gated suite. Contained by keeping the
  job non-blocking and the suite small.

## Known limitations / follow-ups (filed as issues, not built here)

- **Real webhook wire format.** I4 self-signs; it does not prove our parser
  accepts Stripe's real signature header. A single `stripe listen`-delivered
  event in a manual/scheduled check would close this.
- **Concurrent return-vs-webhook race.** `handle_payment_callback` and
  `_process_payment_intent_succeeded` both call `finalize_enrollment`. Sequential
  replay is proven (I4); a *concurrent* fire can hit the enrollment dedup index,
  `die`, return 500, release the `webhook_events` claim, and trigger a Stripe
  retry on an already-successful enrollment. Worth its own invariant + fix later.
- **Currency.** `currency` defaults to `'USD'` and is never asserted against the
  connected account's settlement currency.
- **Application-fee sanity.** No clamp ensures `application_fee_amount < amount`;
  a misconfigured plan percentage would fail at charge time.
- **Refund amount clamp.** `refund` accepts an `amount` with no upper bound vs the
  original charge.

## Success criteria

- The Perl real-Stripe suite passes I1–I7 against Stripe test mode in CI.
- The Playwright smoke confirms one real test card and lands a real enrollment.
- Local `prove -lr t/` and fork PRs remain 100% green (suites self-skip without
  keys).
- Charge creation is idempotent; a double-submit yields at most one charge.
- Refund behavior is plan-configurable and the seeded plans declare it explicitly.
- The onboarding runbook reflects the real launch fee (2%), the refund-fee config,
  and the idempotency key.
