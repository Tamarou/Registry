# PriceOps alignment: one pricing model, applied recursively — design

Date: 2026-08-07
Status: Draft (brainstorm)
Author: perigrin (with Claude)
Supersedes the recommendations in `docs/reviews/2026-08-06-priceops-architecture-review.md`
where the two conflict; see "Corrections to the architecture review" below.

## Problem

Registry is about to take real money and cannot currently reconstruct what it charged.

The 2026-08-06 architecture review asked whether `lib/Registry/PriceOps/` is fit for
purpose and answered "no, not as a layer." It found 47 of 882 non-blank code lines
reachable from a production HTTP request, two modules never called in any commit, a
complete installment stack behind a door nothing opens, and a critical webhook defect
that can permanently lose a paid enrollment.

That review had the wrong lens. It treated `PriceOps` as an accidental name from a
rushed refactor. It is not: **PriceOps is a published methodology** — *The 5 Pillars of
PriceOps*, Tier Inc., 2022, `https://priceops.org/` (domain now parked; read via the
Wayback Machine). The namespace was a deliberate reference to it. Measured against the
methodology it was named for, the implementation satisfies zero of five pillars — and
the reasons why are the same defects the review found, with better names.

This document specifies the corrected architecture and the milestone that lands it.

## What PriceOps is

> "PriceOps is how to operate the pricing."

A methodology for pricing model *definition and implementation* supporting iteration,
safety, and organizational alignment. Explicitly not guidance on what to charge. Its
stated shape of a solution:

- A single source of truth programmatically drives purchase flow, billing, and feature delivery.
- Separation of ownership: a change in one area does not force tightly-coupled changes elsewhere.
- **Pricing plans can be added without changing application code, or affecting existing customers.**

The five pillars:

1. **Pricing Model Definition** — an append-only collection of versioned plans; specific plan versions are immutable, so adding new plan definitions does not affect existing users.
2. **Customer Schedule** — a customer has a schedule of plans in effect at certain times; the plan in effect at a moment determines the price applied.
3. **Metering** — usage is reported to a central store; all features which *might potentially* be monetized are reported, even if currently free or unlimited.
4. **Entitlement Checking** — entitlement resolves by reference to the single source of truth about the schedule and the model; **application code remains agnostic as to the names or versions of plans**.
5. **PriceOps Tooling** — all changes to the pricing model, to a customer's plan or billing, and to which plans display on a pricing page, go through tools working directly against the single source of truth.

## Where Registry stands

| Pillar | Status | Evidence |
|---|---|---|
| 1. Model definition | absent | `registry.pricing_plans` (`sql/test-schema.sql:1200-1218`) has no version column and an `updated_at`; rows mutate in place. Editing `pricing_configuration.percentage` retroactively rewrites the apparent rate of every historical charge (`RevenueShare.pm:31-37`). Moving a tenant between plans rewrites the refund policy of all their past charges (`Payment.pm:114`). Nor is there any Stripe representation to be immutable instead: `stripe_price_id` and `stripe_product_id` appear nowhere in the schema, and `Subscription.pm:121-125` and `Client/Stripe.pm:118-120` build a throwaway Product and Price inline per subscription — so Stripe cannot group revenue by plan and a price change leaves no trace on either side. |
| 2. Customer schedule | absent | `tenants.platform_pricing_plan_id` (`sql/deploy/tenant-platform-pricing-plan.sql:10`) is a single nullable FK — a pointer, not a schedule. #277 is this defect. `RevenueShare.pm:43-45` falls back to Free on NULL, and afterwards nothing distinguishes "charged 0% because Free" from "charged 2%". |
| 3. Metering | absent; the one attempt is dead | `PricingRelationships::_get_usage_data` (`:241-248`, `:255-264`) filters `registry.payments` on a `tenant_id` column the table has never had; its subtest is `plan skip_all`. The actual revenue event — `application_fee_cents`, computed `Payment.pm:43-45`, shipped to Stripe `:96` — is persisted nowhere. #263. |
| 4. Entitlement checking | violated, five live sites | The rate a studio pays is disclosed on the signup page only inside the plan's *name* string, because `templates/tenant-signup/pricing.html.ep:65-67` reads a `revenue_share_percent` key nothing writes; `t/user-journeys/alex/03-platform-billing.t:135-138` therefore asserts it by regexing the plan name. Plus `DAO/PricingPlan.pm:154,170` branching on `plan_type` strings, `RevenueShare.pm:43-45` selecting the Free plan by identity, and `__auto_select_plan` (#275). |
| 5. Tooling | absent | Every platform plan is hand-typed SQL in a migration (`sql/deploy/seed-free-platform-plan.sql:24`, `sql/deploy/unified-pricing-infrastructure.sql:112,138`); no UI writes `percentage` for a platform- or tenant-scope plan. This is why `percentage: 1` is ambiguous between 100% and a 1% typo and why `revenue_share_percent` drifted from `percentage`. `sql/deploy/suspend-rateless-tenant-plans.sql` is a one-shot UPDATE — exactly the out-of-band adjustment Pillar 5 exists to eliminate. |

`RevenueShare.pm` is competent code satisfying none of the pillars: a correct resolver
reading a mutable pointer with no schedule behind it and no record in front of it.

## The core insight: one model, applied recursively

Registry is a platform whose customers are themselves sellers. There is **one relation**,
not two:

> a **provider** sells a **plan version** to a **consumer**.

- provider = registry, consumer = tenant — the platform's revenue share
- provider = tenant, consumer = family — program enrollment, memberships
- provider = tenant, consumer = affiliate — a studio sharing revenue with a referrer

The schema already half-agrees. `sql/deploy/unified-pricing-infrastructure.sql:79-92`
creates the platform *as a tenant* (`registry-platform`, id all-zeros) and seeds its plans
with an `offering_tenant_id` pointing at itself. `registry.pricing_relationships`
(`sql/test-schema.sql:1255-1265`) is `provider_id` / `consumer_id` / `pricing_plan_id`.
The table comment still reads: *"Defines pricing plans (what is offered) —
relationship-agnostic. WHO gets access is handled by pricing_relationships table."*

Two things then went wrong. `offering_tenant_id` was dropped in a "clean architecture"
refactor, and a later migration added `tenants.platform_pricing_plan_id` — which is what
the charge actually reads (`RevenueShare.pm:35,95`) and what signup actually writes
(`TenantPayment.pm:429`). So there are two representations of "which plan is this tenant
on", and **no live production code writes a `pricing_relationships` row**: its only
writers are `PriceOps/PricingRelationships.pm:76` and `PriceOps/UnifiedPricingEngine.pm:57`,
both dead, plus two migrations. A tenant is shown a menu from the relationship table
(`PricingPlanSelection.pm:82-86`) and their choice is recorded somewhere else entirely.

The test written to guard that refactor is `t/dao/pricing-plan-clean-architecture.t` —
the file from #296 that reports PASS on a database it killed at line 21. The invariant
was violated by a later migration and nobody was told, because the guard has never
executed once.

`UnifiedPricingEngine`'s commit message (`31b1f6d`) called itself "the foundation for
evolving Registry into a marketplace ecosystem where any tenant can offer services to
other tenants." That was the right target. It failed because it was built with no caller.
**The structural difference this time is that registry→tenant is consumer #1 of the same
code path tenant→family uses.** The abstraction is exercised by the live money path on
day one or it does not ship.

## The second insight: PriceOps is a translator

The recursion above is the horizontal axis. The vertical one matters as much:

> **The database is the upstream definition of what plans can and should exist.
> Stripe is the source of truth for money movement. PriceOps is the translator between them.**

This is what the layer was for, and it is the discipline that keeps it from becoming a
second billing system. It draws a hard line through the design:

- **Upstream, ours.** What a plan *is*: its versions, components, requirements, who is on
  which one and when. Authored in Postgres, resolved in Postgres. Entitlement checks must
  never round-trip to Stripe — application code asks our resolver, on our data, every request.
- **Downstream, Stripe's.** What actually *happened*: charged, refunded, disputed, invoiced,
  paid out. Our `payments` rows are a projection of that, not an independent ledger. When
  they disagree, Stripe is right and we repair.
- **Between them, PriceOps.** Publishing a plan version projects it into Stripe objects.
  Putting a consumer on a schedule creates the Stripe object that collects. Webhooks
  project the results back.

The pillars line up with Stripe primitives almost exactly, which is the strongest evidence
this is the right seam:

| Pillar | Ours (Postgres) | Stripe primitive |
|---|---|---|
| 1. Model definition | `pricing_plan_versions` + `pricing_components` | Product + Price — **Stripe Prices are already immutable**; you create a new one rather than edit |
| 2. Customer schedule | `pricing_schedules` | Subscription / Subscription Schedule |
| 3. Metering | `metering_events` | Billing Meter Events, for the subset a live component prices |
| 4. Entitlement | `Entitlement->quote` | none — deliberately. This one stays wholly ours |
| 5. Tooling | `./registry pricing` | the CLI publishes; Stripe is written to, never authored in |

The consequence for this milestone is a rule with teeth: **anything Stripe already does, we
call rather than rebuild.** Applied below, it deletes an accrual engine an earlier draft of
this document had specified.

## Acceptance criterion

The milestone has one pass/fail test, and it is Pillar 1's own promise:

> **Author a monthly membership plan through the CLI, enroll a family against it, assert
> they were billed — with no code change in the diff.**

Every design decision below serves that. A milestone that closes every listed issue and
fails this test has failed.

## Design

### Boundary

Two namespaces, one rule each.

**`Registry::PriceOps::*` owns the pricing model, its resolution, and its projection into
Stripe. It never moves money and never writes a payment row.**

The distinction matters: PriceOps *does* call Stripe, but only to publish definitions —
Products, Prices, Subscriptions, meter events. It never creates a PaymentIntent, captures
a charge, or issues a refund. Writing definitions is translation; moving money is not.

| Module | Pillar | Owns |
|---|---|---|
| `PriceOps::Model` | 1 | Plans belong to a provider. Append-only, immutable published versions and their components. Publishing projects the version into a Stripe Product and one Price per component, recording the ids. |
| `PriceOps::Schedule` | 2 | provider → consumer → plan version, effective-dated. Creates the collecting Stripe object for recurring components. |
| `PriceOps::Metering` | 3 | Every monetizable event, including those currently priced at zero. Forwards to Stripe as a meter event when a live component prices that type. |
| `PriceOps::Entitlement` | 4 | Sole read path. Resolves Schedule → Model, returns a Quote. Never touches Stripe. Callers never name a plan. |
| — | 5 | Not a module: `./registry pricing` CLI plus CHECK constraints that make an invalid plan unauthorable. |

**Everything else is money movement and stays outside PriceOps**: `DAO::Payment` (one
payment row, exactly-once intent), `Controller::Webhooks` (atomic claim and process),
`DAO::Subscription`, and a new `Job::ReconcilePayments`. The pillars cover pricing-model
operations; they say nothing about exactly-once charging, and conflating the two is how
the current tangle happened.

**The seam is a Quote.** The charge path asks `Entitlement` exactly once, receives an
immutable quote carrying the plan version id, the line items, and the fee components, and
stamps it onto the payment row. After that the money path never re-reads a plan.

### Data model

**`pricing_plans`** — identity only. `provider_id` (restores `offering_tenant_id`,
permanently this time), `name`, `slug`. Drop `plan_scope`: scope is implied by the
provider. Drop `plan_type`: `'early_bird'` / `'family'` / `'revenue_share'` / `'standard'`
is precisely the string vocabulary Pillar 4 forbids application code from branching on,
and `DAO/PricingPlan.pm:154,170` is the branch that goes.

**`pricing_plan_versions`** — the immutable envelope. `plan_id`, `version`, `requirements`,
`published_at`, `retired_at`, `stripe_product_id`. Immutability enforced by a `BEFORE UPDATE`
trigger rejecting changes to a published version, not by convention — and reinforced
downstream, since the Stripe Price it publishes to is immutable by Stripe's own rules.

**`pricing_components`** — child rows, immutable with their version, any number per version:

- `kind` — `fixed` | `percentage` (`tiered` reserved, rejected by the resolver until it has a consumer)
- `cadence` — `one_time` | `recurring`; `period` (`month` | `year`) when recurring
- `amount_cents` (fixed) or `rate` (percentage)
- `currency` — **on the component, not the version**
- `applies_to` — the metering event type this prices against
- `label` — what the payer sees on the line item
- `stripe_price_id` — filled in at publish. The component is the unit that maps one-to-one
  onto a Stripe Price, which is why the split lives here rather than on the version.

Composition is the point. "2% plus $20/month" is two rows; "5% affiliate share, one-time
setup fee, monthly floor" is three; registry's own 2% is one row with `provider_id` =
registry. No count is special-cased and no combination requires code.

**`pricing_schedules`** — replaces `pricing_relationships`, which already carries
provider/consumer/status and needs versioning and effective dating. `provider_id`,
`plan_version_id`, `effective_at`, `ends_at`, `status`. Consumer as two nullable FKs —
`consumer_tenant_id`, `consumer_user_id` — with a CHECK that exactly one is set, because
Postgres cannot enforce referential integrity on a polymorphic id and the money path is
the wrong place to discover that. `tenants.platform_pricing_plan_id` is **dropped**, not
kept in sync.

**`metering_events`** — `provider_id`, consumer FKs, `event_type`, `quantity`,
`amount_cents`, `occurred_at`, `source` reference. Written for every monetizable event
including zero-priced ones — the pillar's literal wording, and the part Stripe cannot do
for us: Stripe only holds events against a meter that already exists, and the whole point
of Pillar 3 is recording volume *before* anyone has decided to charge for it. Events whose
`event_type` is priced by a live component are forwarded to Stripe as meter events, and
from there Stripe does the arithmetic and raises the invoice. Ours is the record of what
happened; Stripe's is the thing that bills.

**Quote columns on `payments`** — `plan_version_id`, `application_fee_cents`, and the
resolved fee rate, stamped in `_record_intent` (`Payment.pm:206-216`) beside the intent
id. This single change closes four review findings at once: the fee is never recorded,
the rate can be retroactively rewritten, the refund policy follows a tenant between plans,
and "0% because Free" is indistinguishable from "2%".

These columns are also what makes the row reconcilable. Stripe is authoritative for the
amount; what Stripe cannot tell us is *which plan version produced it*. The quote stamp is
the join between the definition side and the money side, and it is the only thing on the
payment row that is ours rather than a projection.

**`billing_periods`** — **deleted.** `sql/test-schema.sql:766-780` (`period_start`,
`period_end`, `calculated_amount`, `stripe_invoice_id`, `processed_at`) is a period-end
accrual invoice, and a period-end accrual invoice is a Stripe Invoice. Building our own
means computing an amount Stripe will also compute, and then owning the difference. The
translator rule settles it: we report meter events, Stripe accrues and invoices, and
`invoice.*` webhooks project the result back. If local invoice history is later wanted for
reporting, it is a projection keyed on `stripe_invoice_id` — written from webhooks, never
computed. `calculated_amount` was also the last `numeric(10,2)` money column in the schema,
so this closes that too.

`payment_items` (`sql/test-schema.sql:1122-1131`) is reused as-is for quote line items.
#292's broken name interpolation is fixed by having components generate their own labels
rather than a caller string-building them.

### Collection mechanisms

Cadence × kind is four mechanisms. All four ship.

| Component | Example | Collected by | Status |
|---|---|---|---|
| `fixed` / `one_time` | $150 enrollment; $50 setup fee | PaymentIntent | exists |
| `percentage` / `one_time` | registry's 2%; an affiliate cut | Stripe `application_fee` at charge time | exists — `RevenueShare` |
| `fixed` / `recurring` | $30/mo membership; Registry Plus $100/mo | Stripe Subscription | exists — `DAO::Subscription` |
| `percentage` / `recurring` | 2% of the month's volume, billed at period end | Stripe metered Price on the consumer's subscription, fed by meter events | **new** |

`percentage`/`one_time` and `percentage`/`recurring` are different products, not a
formatting choice: the first is collected per transaction as money moves, the second
accrues against metered volume and bills once. Only the second makes Pillar 3 real rather
than analytical, which is why it ships in this milestone rather than after it.

The new mechanism is new to *Registry*, not to Stripe. Its implementation is a metered
Price created at publish, a meter event per priced metering row, and an `invoice.paid`
handler. There is no accrual job and no amount computed on our side.

### Resolution

```
Registry::PriceOps::Entitlement->quote($db, { provider, consumer, product, at }) -> Quote
```

1. Schedule row for (provider, consumer) in effect at `at` → its plan version governs.
2. Otherwise the product's own plan version — the transactional case.
3. Evaluate the version's `requirements`. Early-bird date logic lives here, comparing
   like units — fixing `DAO/PricingPlan.pm:154-166`, which compares `time()` (~1.78e9)
   against a de-hyphenated cutoff (`20261231`) and is therefore true for every date.
4. Emit one line per component whose `applies_to` matches.
5. **Refuse when nothing resolves.**

Step 5 is the entire fix for the free-enrollment defect. Today absence and zero are the
same value: `Payment.pm:517-518` skips a session with no plan, contributing 0, and
`WorkflowSteps/Payment.pm:47-49` reads a 0 total as "free program" and routes to
`create_demo_enrollments` — enrolling every child with no payment row and no Stripe call.
A `Quote` makes the two different by construction: no version resolved is an error; a
version whose components sum to zero is a valid free enrollment. `calculate_enrollment_total`
(`Payment.pm:499-546`) is deleted rather than patched, which also removes the unordered
`$pricing_plans->[0]` selection.

`RevenueShare::revenue_share_fraction_for_tenant` and `refund_application_fee_for_tenant`
keep their names and signatures — `docs/operations/sacp-stripe-connect-onboarding.md:183,202`
names both by fully-qualified package as a live operational contract — and become thin
wrappers over `quote(provider: registry, consumer: tenant)`. `_coerce_pct`'s guard tightens
from `$raw <= 1` to `$raw <= 0.5`, with a message naming both readings, so the ambiguous
`1` fails at plan authoring rather than at payout.

### Money movement (not PriceOps)

- **Webhook atomicity.** Claim and processing collapse into one transaction: BEGIN,
  `INSERT ... ON CONFLICT DO NOTHING`, process, COMMIT. A crash rolls the claim back with
  the work and Stripe's retry heals it for free — strictly less code than the current
  claim-at-`Webhooks.pm:46-50` / release-in-`catch`-at-`:85` pair. Add `processed_at` to
  `registry.webhook_events`.
- **Fail loud on writes.** Every money-path `$self->update` becomes `save`:
  `Webhooks.pm:136`, `Payment.pm:206-216`, `:208`, `:221`. `Registry::DAO::Object::update`
  (`Object.pm:38-49`) carps and continues, and also returns a new object rather than
  mutating `$self`, so the in-memory row goes stale even on success. #262, #280.
- **Reconciliation.** `Registry::Job::ReconcilePayments`, registered like the existing
  jobs (`Registry.pm:72-75`): payments `pending` beyond an interval with a
  `stripe_payment_intent_id` set. It retrieves the intent and writes down what Stripe says —
  it never infers. Stripe being the source of truth is what makes this job trivially
  correct instead of a second opinion. Step 1 closes the hole; this finds what the hole
  already ate.
- **Disputes.** A `charge.dispute.created` branch that at minimum alerts. Destination
  charges mean the tenant has already been paid when funds are clawed back.
- Plus #247 (payment finalization spanning two schemas without a shared transaction),
  #284, #289, #293, and the tenant-subscription lifecycle fix: pass `$tenant_id` through
  to `create_subscription_with_config` (`TenantPayment.pm:340-344` vs `Subscription.pm:118`)
  so the five handlers that bail on `return unless $tenant_id` can run, and give
  `billing_status` at least one reader.

## What gets deleted

Installments are cut. ~3,500 lines across `lib/` and `t/`, the `Webhooks.pm:69,204-295`
branch, and forward migrations for `payment_schedules` and `scheduled_payments`. Close
#295 and #279 as won't-do. Rationale: unreachable for eleven months, two independent
breaks from working (an orphaned workflow step *and* a registry-scoped webhook classifier
that cannot see tenant-schema rows), drifted from `Payment.pm` on four separate fixes, and
never offered to a single parent. It also frees the name `Schedule`, which
`PriceOps::PaymentSchedule` currently occupies for an unrelated meaning.

Also deleted: `t/dao/pricing-plan-clean-architecture.t` (#296),
`t/e2e/installment-payment-enrollment.t` and
`t/controller/admin-installment-payment-dashboard.t` (both DAO CRUD misfiled under names
that make the feature read as covered), the orphaned discount configuration in
`templates/pricing-plan-creation/requirements-rules.html.ep` and `RequirementsRules.pm:46-90`,
and `Family::sibling_discount_eligible`.

`PriceOps/UnifiedPricingEngine.pm` and `PriceOps/PricingRelationships.pm` are deleted **in
Leg 3, not before** — they are the only code in `lib/` that can write a
`pricing_relationships` row, so they must be replaced rather than removed ahead of the
replacement. `DAO::PricingRelationshipEvent` dies with them. Close #76.

## Sequencing

| Leg | Content | Depends on |
|---|---|---|
| 0 | Webhook atomicity; `update` → `save` on money paths | — |
| 1 | Safe deletions: installments, misfiled tests, #296, discount form | — |
| 2 | `pricing_plans` / `pricing_plan_versions` / `pricing_components`; migrate existing plans to v1 | 1 |
| 2b | Publish projection: version → Stripe Product, component → Stripe Price; ids recorded; `Subscription.pm` and `Client/Stripe.pm` stop building inline `price_data` | 2 |
| 3 | `pricing_schedules`; migrate `pricing_relationships` + `platform_pricing_plan_id`; drop the FK; delete the two dead modules | 2 |
| 4 | `Entitlement` + `Quote`; rewire the charge; delete `calculate_enrollment_total`; refuse-not-zero | 3 |
| 5 | Quote columns on `payments`; fee recorded; `AdminDashboard.pm:36` corrected | 4 |
| 6 | `Metering` + Stripe meter-event forwarding | 3 |
| 7 | `percentage`/`recurring`: metered Price at publish, `invoice.*` handlers; drop `billing_periods` | 2b, 5, 6 |
| 8 | Pillar 5: `./registry pricing` CLI + CHECK constraints; retire hand-typed SQL seeds | 2 |
| 9 | `Job::ReconcilePayments`; disputes; subscription lifecycle `tenant_id` | 0 |

Leg 0 ships alone and first: it can lose a paid enrollment today and depends on nothing
else here.

## Testing

Strict TDD per `CLAUDE.md`; 100% pass rate; pristine output. Full suite is
`STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/` (~76 min).

One invariant test per pillar:

1. A published plan version cannot be updated — the trigger raises.
2. A quote resolved at time T returns the version in effect at T after a later version is published.
3. A zero-priced enrollment on a Free-tier tenant still writes a `metering_events` row.
4. No production code path reads a plan by name; the resolver rejects a version it cannot price.
5. A plan authored via CLI is byte-identical to one authored by the workflow; a rateless percentage plan is rejected at authoring.

Plus one translator invariant: publishing a version twice is idempotent and creates exactly
one Stripe Product, and no code path outside `PriceOps::Model` sends `price_data` — a grep
assertion, because that is how the current inline-Price defect got in and how it would
come back.

Plus the money-movement tests: a webhook killed mid-processing leaves no claim (Leg 0);
a `RevenueShare` die surfaces through the charge as a readable error with no second
payment row and no spent idempotency token — twenty lines added to
`t/dao/payment-intent-destination-charge.t`, closing a gap the review found where all five
die paths are unit-covered and none is covered through a request.

And the acceptance test above, which is the milestone gate.

The suite is not pristine today: `t/dao/scheduled-payment.t:21`,
`t/dao/payment-schedule-race-condition.t:24`, `t/dao/payment-schedule.t:21` and
`t/controller/installment-payment-webhooks.t:24` set
`$ENV{STRIPE_SECRET_KEY} = 'sk_test_mock_key_for_testing'`, overriding the placeholder and
making real failing HTTPS calls whose warnings land in output. Leg 1 deletes all four.

## Corrections to the architecture review

1. The review called the `PriceOps` name accidental and recommended `Registry::Money`.
   Wrong — the name is a deliberate reference to the methodology. It stays.
2. The review recommended deleting `registry.billing_periods`. **Right conclusion, thin
   reasoning** — it argued from the table being unused. The real argument is that a
   period-end accrual invoice is a Stripe Invoice, and building our own means computing an
   amount Stripe also computes and then owning the difference. An earlier draft of this
   document reversed the review and kept the table as the accrual store for
   `percentage`/`recurring`; the translator rule rules that out. Delete both, and close
   task #14 as delete.
3. The review recommended "subtract first" for all dead code. Wrong for
   `PricingRelationships.pm` and `UnifiedPricingEngine.pm`, which are the only writers of
   `pricing_relationships`. They go in Leg 3, with their replacement.
4. The review filed #296 as test hygiene. It is architectural: that test is the guard for
   the relationship-agnostic-plans invariant, and the invariant was violated by a later
   migration while the guard sat dead.
5. Three issues in the money cluster are already fixed and should be closed rather than
   scheduled: **#267** (`RevenueShare.pm:35` resolves from the tenant's plan; `0ec723f`→`10932e3`),
   **#281** (`_to_cents` no longer exists anywhere in `lib/`), **#288** (`TenantPayment.pm:145`
   passes `amount_cents` into `monthly_amount` → `Subscription.pm:125` `unit_amount`).
   #288 is still labelled `blocker`/`critical-impact`.

## Out of scope

- **`tiered` pricing.** Reserved in the `kind` vocabulary, rejected by the resolver. No named consumer.
- **Admin UI for authoring platform plans.** Pillar 5 is satisfied by `./registry pricing`
  plus constraints. UI when a human who is not perigrin needs to author a plan.
- **Sales tax and merchant of record.** No code, but the destination-charge design implies
  the tenant and that should be written down before the first charge.
- **Refunds (#286).** The resolver and `t/dao/refund-application-fee.t` stay as they are.
  Refunds get their design after this lands; the drop-approval workflow's own bug
  (`ProcessAdminDropDecision.pm:33` advances one step of six while
  `templates/admin-drop-approval/complete.html.ep:7` reports success) is an operator-trust
  bug and gets its own issue now.

## Open questions

1. **Consumer identity for families.** `pricing_schedules.consumer_user_id` assumes the
   paying adult is the consumer. Registry has both `users` and `families` — a membership
   sold to a household rather than an individual may want `consumer_family_id` as a third
   FK. Deciding this before Leg 3 is cheaper than after.
2. **#294, collapsing `registry-platform` into `registry`.** This design makes the platform
   tenant load-bearing as the provider identity, which strengthens the case for collapsing
   the all-zeros row and the hardcoded `PricingPlanSelection.pm:14` constant into the real
   registry tenant. In scope for Leg 3 or deferred?
3. **Which Stripe account holds a tenant's Prices.** Registry uses destination charges, so
   a family's charge is created on the platform account with `transfer_data[destination]`
   set to the tenant. That suggests a tenant's program Prices also live on the platform
   account, keyed to the tenant by metadata — but a tenant running their own subscription
   billing would want them on their connected account. The two are not interchangeable and
   the answer decides what Leg 2b builds. Needs a test-mode spike before Leg 2b, not a
   guess.
4. **Component-level currency and mixed-currency plans.** Currency lives on the component.
   A version with components in two currencies is expressible; whether it is *chargeable*
   depends on Stripe behaviour we have not tested. Recommend a CHECK enforcing one currency
   per version until there is a reason otherwise.
