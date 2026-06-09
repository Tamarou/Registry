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

### 2. Payment data → the tenant schema (only the three tenant-scoped DAOs)
**Audit result (verified against code — do NOT blanket-unqualify):**
- **Tenant-scoped → unqualify:** `Payment`, `PaymentSchedule`, `ScheduledPayment`. These hold
  enrollment payment records owned by the tenant.
- **Platform-scoped → KEEP `registry.`-qualified:** `PricingRelationship`,
  `PricingRelationshipEvent`, `BillingPeriod`. Their FKs reference `registry.users` /
  `registry.tenants` / `registry.pricing_relationships`; they model the platform↔tenant
  subscription and the 2.5% revenue-share, and are used by `WorkflowSteps/PricingPlanSelection`
  in **tenant-signup** (registry context). Unqualifying them would break platform subscription
  billing — a regression worse than the bug. They are explicitly out of scope.

Unqualify `Payment`/`PaymentSchedule`/`ScheduledPayment` to use the unqualified table so the
connection's `search_path` (tenant) governs — the PricingPlan fix (#231/#235) generalized.
**The audit must cover raw SQL inside methods, not just `sub table`** — e.g.
`PaymentSchedule::cancel_with_pending_payments` and `PriceOps::ScheduledPayment` hardcode
`registry.scheduled_payments`/`registry.payment_schedules` in inline SQL. Grep
`registry\.(payments|payment_schedules|scheduled_payments)` across `lib/` and convert each.

**Tables may not exist in existing tenant schemas.** `clone_schema` copies registry's tables
*at provisioning time*; tenants provisioned before the payment migrations lack `payments` /
`payment_schedules` / `scheduled_payments`. The migration must **backfill** them per existing
tenant (`CREATE TABLE IF NOT EXISTS <slug>.payments (LIKE registry.payments INCLUDING ALL)`
with FKs rewritten to the tenant schema), using the per-tenant loop pattern from
`enrollment-payment-dedup.sql`. (Newly-provisioned tenants get them via clone.)

With payments in the tenant schema, **`payments_user_id_fkey` resolves naturally** (payer and
payment co-located). A data-isolation test asserts tenant payments stay in the tenant schema.

**`enrollments.payment_id` FK must be repointed (HIGH).** Today it is
`REFERENCES registry.payments(id)` (`add-payment-to-enrollments.sql`). Once payments live in
the tenant schema this cross-schema FK breaks. Migration: drop it and re-add **unqualified**
(`REFERENCES payments(id)`, resolves via search_path) for the registry template AND every
tenant schema (same per-tenant loop).

**Platform revenue-share aggregation (deferred dependency).**
`PriceOps::PricingRelationships._get_usage_data` computes the platform's billing by querying
`FROM registry.payments` **across all tenants**. Once payments move to tenant schemas this
cross-tenant query no longer sees them. Under the Connect model the 2.5% is collected at
charge time via `application_fee_amount`, so this manual computation likely becomes reporting
rather than fee-collection — but it must be redesigned (cross-schema aggregation, or driven
from Stripe application-fee records) and is a noted dependency, not silently left broken.

`registry.webhook_events` (global Stripe-event dedup) stays in registry.

### 3. Charge routing — destination charge with application fee
In the enrollment Payment step (`WorkflowSteps/Payment.pm` `create_payment`):
- Resolve the tenant's `stripe_connect_account_id` + readiness from the tenant record.
- **Readiness gate:** if the tenant has no connected account, or `charges_enabled` /
  `details_submitted` is false, **refuse paid enrollment** with a clear, user-facing error
  (we cannot legally charge). Free enrollment ($0) is unaffected.
- Create the PaymentIntent as a **destination charge**: `transfer_data[destination] = <acct>`,
  `application_fee_amount = round(0.025 × total_cents)`, **and `on_behalf_of = <acct>`**.
  `on_behalf_of` is what actually makes the **tenant the settlement merchant and bearer of the
  Stripe processing fee** (the decided model) — without it the *platform* would absorb the
  Stripe fee and merely recoup via the application fee. Tuition settles to the tenant's
  balance; Registry collects the 2.5%. Continue snapshotting `metadata.tenant_slug` (already
  done) and `metadata.payment_id`.

### 4. Webhook → tenant-scoped finalization (explicit rewrite — HIGH)
`_process_payment_intent_succeeded` currently does `Payment->find($dao->db, ...)` on the
**registry** connection and only later `connect_schema`s for `finalize_enrollment`. After the
move, the payment lives in the tenant schema, so that `find` returns `undef` and the handler
**silently returns without finalizing** (and the dedup claim means Stripe won't retry). It
must be rewritten to do everything on the tenant connection:
1. Read `metadata.tenant_slug` from the event (corroborate with the Connect `account` field).
2. `my $tdb = $dao->connect_schema($slug)->db;`
3. `Payment->find($tdb, { id => $payment_id })` — find the payment **in the tenant schema**.
4. Mark it completed on `$tdb`.
5. `finalize_enrollment($tdb)`.
If `tenant_slug` is missing or the payment isn't found, log and return 500 so Stripe retries
(don't swallow). Add an `account.updated` handler to refresh the tenant readiness booleans
(§1). Destination-charge `payment_intent.succeeded` events arrive on the **platform** webhook
(not the connected account's), and `metadata` is preserved — confirm during implementation.

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
| Unqualifying a platform-scoped DAO breaks tenant-signup / revenue-share billing | Only the 3 tenant-scoped DAOs move; the 3 platform-scoped pricing/billing DAOs stay `registry.`-qualified (§2, verified by FK targets + callers). |
| `enrollments.payment_id` FK / webhook payment lookup break on the move | Explicit FK-repoint migration (§2) and webhook rewrite to the tenant connection (§4). |
| Existing tenant schemas lack the payment tables | Backfill migration per existing tenant (§2). |
| Stripe fee borne by platform instead of tenant | Set `on_behalf_of=<acct>` on the PaymentIntent (§3). |
| Webhook can't resolve tenant | `metadata.tenant_slug` is snapshotted at charge creation; the Connect `account` field corroborates; fall back to logging + 500 so Stripe retries (existing pattern). |
| Mixed account types later (Standard vs Express) | Accepted; charge-routing code is identical across types. |

## Testing strategy

TDD at the DAO/step/webhook layers + an integration test for the paid enrollment path under
the harness with Stripe test mode. Regression: the full `t/dao/` + `t/controller/` suites and
the payment/webhook tests (`payment-workflow-step`, `installment-webhook-processing`,
`scheduled-payment`, etc.) stay green; the tenant-scoping of the billing DAOs must not break
the platform-subscription billing path (tenant-signup) — verify explicitly, since that path
also uses some of these DAOs.

## Resolved by spec review (do not re-litigate)
- **DAO classification (was the big open question):** `Payment`/`PaymentSchedule`/
  `ScheduledPayment` are tenant-scoped (move); `PricingRelationship`/`PricingRelationshipEvent`/
  `BillingPeriod` are platform-scoped (stay `registry.`). Verified via their FK targets and
  the tenant-signup `PricingPlanSelection` caller. §2.
- Payment tables are NOT guaranteed present in existing tenant schemas → backfill migration
  required. §2.
- `enrollments.payment_id` FK and the webhook payment lookup both break on the move and have
  explicit migration/rewrite steps. §2/§4.
- Fee semantics require `on_behalf_of` to make the tenant bear the Stripe fee. §3.

## Open questions (resolve during planning)
- Exact `application_fee_amount` rounding + currency handling.
- Whether installment/scheduled payments are in SACP's launch scope or one-time only.
- Redesign of `PriceOps::PricingRelationships._get_usage_data` (cross-tenant payment
  aggregation) once payments are tenant-scoped — likely superseded by Connect `application_fee`
  collection; confirm it doesn't silently under-report platform revenue in the interim.
