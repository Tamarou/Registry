# MVP Stripe Connect + Tenant-Scoped Payments — Design

ABOUTME: Lets a tenant take paid enrollment where tuition settles into the tenant's own
ABOUTME: Stripe (Standard) connected account, with payment data isolated in the tenant schema.

- Status: Draft (pending review)
- Date: 2026-06-09
- Drives: SACP paid afterschool launch (compliance: money must settle into SACP's account,
  Registry cannot be merchant-of-record). Closes the isolation bug in #237.
- Part of the larger PriceOps Connect epic (#23/#76); this is the **MVP slice**. Deferred
  pieces are listed in §Non-goals.

## Problem

Paid tenant enrollment is broken and non-compliant today:
- `Registry::DAO::Payment` (and the billing DAOs) hardcode `registry.payments`; a tenant
  parent (who lives only in the tenant schema) hits `payments_user_id_fkey` and the payment
  insert fails (verified — see #237). Free enrollment works; paid does not.
- Even when it doesn't error, payments centralize in `registry.payments` — commingling every
  tenant's financial records — and **Registry would be merchant-of-record holding tenant
  funds**, which SACP's launch cannot accept. Tuition must land in SACP's own account.

Production already has Stripe **Connect enabled** (platform `acct_1NBjkkLMFKfcYAvR`) with
working `charges_enabled` connected accounts, so the platform capability exists; SACP is not
yet onboarded.

## Decisions (settled with the requester)

- **Tenant-scoped payments** (payment data lives in the tenant schema), not platform-central.
- **Per-tenant Stripe Connect**, **Standard** accounts. SACP onboarded **manually** for the
  MVP (mirroring the existing standard account); self-serve onboarding is deferred.
- **2.5% revenue share** via `application_fee_amount` on **destination charges**.
- **Tenant absorbs Stripe's processing fee** (Standard + destination-charge default).
- **Readiness gate** built in now (`charges_enabled`/`details_submitted`) so self-serve
  onboarding is later purely additive. Mixed account types (Standard now, possibly Express
  for self-serve later) are acceptable.

## Design

### 1. Connected account + readiness on the tenant
Add to `registry.tenants`: `stripe_connect_account_id text`, `stripe_charges_enabled boolean
default false`, `stripe_details_submitted boolean default false`. SACP's Standard `acct_…` is
onboarded manually in Stripe and these fields set (a documented ops step, not a UI flow). An
`account.updated` Connect webhook refreshes the readiness booleans.

### 2. Payment data → the tenant schema
`Payment`, `PaymentSchedule`, `ScheduledPayment`, `BillingPeriod`, `PricingRelationship`,
`PricingRelationshipEvent` stop hardcoding `registry.*` and use the unqualified table so the
connection's `search_path` (tenant) governs — the generalization of the PricingPlan fix
(#231/#235). The tables already exist per-tenant via `clone_schema`. **The
`payments_user_id_fkey` then resolves naturally**: payer and payment are co-located in the
tenant schema (no FK drop needed). A migration relocates any existing registry-resident
rows if required; a data-isolation test asserts tenant payments stay in the tenant schema.

`registry.webhook_events` (global Stripe-event dedup) stays in registry.

### 3. Charge routing — destination charge with application fee
In the enrollment Payment step (`WorkflowSteps/Payment.pm` `create_payment`):
- Resolve the tenant's `stripe_connect_account_id` + readiness from the tenant record.
- **Readiness gate:** if the tenant has no connected account, or `charges_enabled` /
  `details_submitted` is false, **refuse paid enrollment** with a clear, user-facing error
  (we cannot legally charge). Free enrollment ($0) is unaffected.
- Create the PaymentIntent as a **destination charge**: `transfer_data[destination] =
  <acct>`, `application_fee_amount = round(0.025 × total_cents)`. Tuition settles to the
  tenant's balance; Stripe fees come off the tenant's account (Standard default); Registry
  collects the 2.5%. Continue snapshotting `metadata.tenant_slug` (already done) and
  `metadata.payment_id`.

### 4. Webhook → tenant-scoped finalization
`payment_intent.succeeded` handling: resolve the tenant from `metadata.tenant_slug` (already
snapshotted) — corroborated by the Connect event's `account` field — `connect_schema($slug)`,
find the payment **in the tenant schema**, mark it completed, and finalize the enrollment
there (enrollment finalization already runs in-tenant). Add an `account.updated` handler to
refresh the tenant readiness booleans (§1).

### 5. Test coverage (the gap that hid #237)
End-to-end paid enrollment in a tenant, **Stripe test mode + a test connected account** (never
the live `sk_live`):
- PaymentIntent carries `transfer_data[destination]` and the 2.5% `application_fee_amount`.
- The payment row and the enrollment land in the **tenant** schema, not registry.
- The readiness gate refuses paid enrollment when the tenant has no/!ready connected account.
- The webhook finalizes the enrollment in-tenant.

## Non-goals (deferred — rest of the Connect epic)

- **Self-serve Connect onboarding** (Account Links flow, "Connect your Stripe" UI). Forward-
  compatible by design: it populates the same `stripe_connect_account_id` and flows through
  the readiness gate this MVP builds — additive, no rework, no re-onboarding of SACP.
- Express accounts, payout/fee-reporting dashboards, account-requirement edge-case UX at
  scale, Accounts v2 migration. (Stripe nudges toward Accounts v2; this MVP uses the
  supported PaymentIntent `transfer_data` destination-charge pattern.)

## Risks / mitigations

| Risk | Mitigation |
| --- | --- |
| Charging without a ready merchant account | Readiness gate (§3) refuses paid enrollment unless `charges_enabled` + `details_submitted`; free unaffected. |
| Live Stripe key in tests | Tests use a Stripe **test** key + test connected account; CI strips `STRIPE_SECRET_KEY` (already done for the harness). |
| Relocating existing registry-resident payment rows | Migration handles existing rows; pre-alpha means little/no real paid data to move — confirm before deploy. |
| Webhook can't resolve tenant | `metadata.tenant_slug` is snapshotted at charge creation; the Connect `account` field corroborates; fall back to logging + 500 so Stripe retries (existing pattern). |
| Mixed account types later (Standard vs Express) | Accepted; charge-routing code is identical across types. |

## Testing strategy

TDD at the DAO/step/webhook layers + an integration test for the paid enrollment path under
the harness with Stripe test mode. Regression: the full `t/dao/` + `t/controller/` suites and
the payment/webhook tests (`payment-workflow-step`, `installment-webhook-processing`,
`scheduled-payment`, etc.) stay green; the tenant-scoping of the billing DAOs must not break
the platform-subscription billing path (tenant-signup) — verify explicitly, since that path
also uses some of these DAOs.

## Open questions (resolve during planning)

- Do any of the billing DAOs serve a genuinely platform-level (registry) purpose that must
  NOT move to tenant scope (e.g. the tenant-signup subscription/`PricingRelationship` used by
  `PricingPlanSelection`)? Audit each of the six per-caller before unqualifying; some may be
  platform-scoped and stay registry-qualified.
- Exact `application_fee_amount` rounding + currency handling.
- Whether installment/scheduled payments are in SACP's launch scope or one-time only.
