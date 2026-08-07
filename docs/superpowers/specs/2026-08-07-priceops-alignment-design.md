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
| 1. Model definition | absent | `registry.pricing_plans` (`sql/test-schema.sql:1200-1218`) has no version column and an `updated_at`; rows mutate in place. Editing `pricing_configuration.percentage` retroactively rewrites the apparent rate of every historical charge (`RevenueShare.pm:31-37`). Moving a tenant between plans rewrites the refund policy of all their past charges (`Payment.pm:114`). Nor is there any Stripe representation to be immutable instead: `stripe_price_id` and `stripe_product_id` appear nowhere in the schema, and `Subscription.pm:121-125` builds a throwaway Product and Price inline per subscription — so Stripe cannot group revenue by plan and a price change leaves no trace on either side. `Service::Stripe:182-202` already implements the Product and Price API; it has no production caller. |
| 2. Customer schedule | absent | `tenants.platform_pricing_plan_id` (`sql/deploy/tenant-platform-pricing-plan.sql:10`) is a single nullable FK — a pointer, not a schedule. #277 is this defect. `RevenueShare.pm:43-45` falls back to Free on NULL, and afterwards nothing distinguishes "charged 0% because Free" from "charged 2%". |
| 3. Metering | absent; the one attempt is dead | `PricingRelationships::_get_usage_data` (`:241-248`, `:255-264`) filters `registry.payments` on a `tenant_id` column the table has never had; its subtest is `plan skip_all`. The actual revenue event — `application_fee_cents`, computed `Payment.pm:43-45`, shipped to Stripe `:96` — is persisted nowhere. #263. |
| 4. Entitlement checking | violated, five live sites | The rate a studio pays is disclosed on the signup page only inside the plan's *name* string, because `templates/tenant-signup/pricing.html.ep:65-67` reads a `revenue_share_percent` key nothing writes; `t/user-journeys/alex/03-platform-billing.t:135-138` therefore asserts it by regexing the plan name. Plus `DAO/PricingPlan.pm:154,170` branching on `plan_type` strings, `RevenueShare.pm:43-45` selecting the Free plan by identity, and `__auto_select_plan` (#275). |
| 5. Tooling | absent | Every platform plan *in the database* is hand-typed SQL in a migration (`sql/deploy/seed-free-platform-plan.sql:24`, `sql/deploy/unified-pricing-infrastructure.sql:112,138`). The authoring workflow can write one — `PricingPlanBasics.pm:88-93` offers `platform` and `tenant` scopes, `PricingModel.pm:94-99` writes `percentage` — but nothing in production came from it, so the vocabulary the workflow writes has never been checked against the one the charge path reads. Two authoring paths, one of them exercised. This is why `percentage: 1` is ambiguous between 100% and a 1% typo and why `revenue_share_percent` drifted from `percentage`. `sql/deploy/suspend-rateless-tenant-plans.sql` is a one-shot UPDATE — exactly the out-of-band adjustment Pillar 5 exists to eliminate. |

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

### Whose Stripe account: the provider's

Tenants own their own data. A plan a tenant authors is theirs, so it publishes to *their*
connected account. Registry's own platform plans publish to the platform account. Stated
once: **the provider's account holds the plan** — which is the horizontal recursion
projected onto Stripe, and needs no special case for either direction.

This has a consequence worth stating plainly rather than discovering in Leg 6. Stripe
objects do not cross accounts: a Price on a connected account cannot be referenced by a
PaymentIntent created on the platform account. Tenant→family therefore moves from
**destination charges to direct charges** — created on the tenant's account with
`Stripe-Account`, with Registry's share as `application_fee_amount`.

Today `Payment.pm:94-96` sends `transfer_data[destination]` and `on_behalf_of`, so the
tenant is already the settlement merchant and already bears Stripe's fees. What changes is
which account the charge object lives on, and with it the Customer, the Price, and the
receipt.

Three things fall out in our favour, which is usually the sign a boundary is in the right
place:

- **Dispute liability moves to the tenant**, where the service was delivered and the money
  landed. Stripe is explicit that for destination charges, with or without `on_behalf_of`, it
  "debits dispute amounts and fees from your platform account" — recovering them means
  reversing the transfer, which is subject to cross-border restrictions that can leave a
  platform unable to repay a tenant it wrongly clawed back from. That is a whole risk
  programme this document would otherwise have to specify, deleted by choosing the other
  charge type.
- **Merchant of record stops being an open question.** With direct charges the tenant is
  unambiguously the seller; sales-tax obligation follows them, not us.
- **The missing-`tenant_id` webhook bug becomes structural rather than a metadata patch.**
  Connected-account events arrive with `account: acct_…`, which identifies the tenant
  without anyone remembering to set metadata. The five lifecycle handlers that currently
  bail on `return unless $tenant_id` get their answer from the envelope.

A fourth follows from the dispute requirement: Stripe's embedded dispute components are
built for direct charges, and under destination charges they cover only `on_behalf_of`
charges behind an extra opt-in.

The cost is real and is scheduled as its own leg: the Payment Element needs
`stripeAccount`, families become Customers on the tenant's account, the webhook endpoint
must accept Connect events, and the money-path E2E suite is re-cut against direct charges.
It is a change of model rather than a migration of data, because no tenant has onboarded yet
— which is precisely why it has to happen now rather than after the first one does.

## Acceptance criterion

The milestone has one pass/fail test, and it is Pillar 1's own promise:

> **Author a monthly membership plan through the CLI, enroll a family against it, assert
> they were billed — with no code change in the diff.**

"With no code change in the diff" is the point and is not assertable by a test, so the
criterion is made executable as `t/e2e/author-a-new-plan.t`, gated on three things a test
*can* check:

1. The test shells out to `./registry pricing` with a plan shape that appears nowhere in
   `lib/` — a monthly membership, which no current code path knows how to price — and the
   command exits zero.
2. It enrolls a family against the resulting plan through the ordinary enrollment path and
   asserts a Stripe subscription exists on the tenant's account with the expected amount,
   currency and interval.
3. It asserts the plan's name and slug appear in no file under `lib/` — the grep that
   stands in for "no code change," and the same shape as the `price_data` assertion under
   "Testing". A plan whose name has to be taught to the code is a plan that failed Pillar 1.

The honest gap: no test written today can prove that a plan shape *invented tomorrow* needs
no code. Point 3 is the closest mechanical proxy and it is a proxy. What closes the gap is
the second such test, written when a real second plan shape is wanted, and it costs
whatever it costs — that cost being the actual measurement.

Every design decision below serves this criterion. A milestone that closes every listed
issue and fails it has failed.

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
| `PriceOps::Metering` | 3 | Every monetizable event, including those currently priced at zero. Forwarding to Stripe as meter events is deferred with usage-based pricing; recording is not. |
| `PriceOps::Entitlement` | 4 | Sole read path. Resolves Schedule → Model, returns a Quote. Never touches Stripe. Callers never name a plan. |
| — | 5 | Not a module: `./registry pricing` CLI plus CHECK constraints that make an invalid plan unauthorable. `Registry::Command::*` already establishes the shape, and its `run($cmd, $schema, @args)` signature already carries the schema argument the provider identity needs. |

**The existing authoring workflow is in scope and is the larger half of Pillar 1.** Dropping
`plan_scope`, `plan_type` and `pricing_model_type` invalidates the five step classes of
`workflows/pricing-plan-creation.yaml:13,18,23,28,33` — `PricingPlanBasics.pm:18,20,47,49`,
`PricingModel.pm:17`, `ResourceAllocation.pm:133`, `RequirementsRules.pm:145`,
`ReviewActivatePlan.pm:102-105,169-174` — about 1,028 lines plus
`templates/pricing-plan-creation/`, and the `pricing_plans_plan_scope_check` constraint. The
workflow is rewritten to author versions and components, not merely repointed.

**Two more step classes read that vocabulary from other live workflows**, and an earlier draft
filed both under the authoring workflow, which would have left them broken in place.
`PricingPlanSelection.pm:93,147` belongs to `workflows/tenant-signup.yml:18` — the path a
tenant takes to choose their platform plan, so it is on the signup money path, not the
authoring one. `GenerateEvents.pm:100` belongs to
`workflows/program-location-assignment.yml:21`. Neither is rewritten by Leg 5; both are
repointed at `Entitlement` in Leg 8, which is where their vocabulary actually goes away.
This is not optional polish: the milestone's own Pillar 5 test asserts that a plan authored
through the CLI is identical to one authored through the workflow, which cannot hold while
the workflow writes a vocabulary that no longer exists.

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
`published_at`, `stripe_product_id`. Immutability enforced by a `BEFORE UPDATE`
trigger rejecting changes to a published version, not by convention — and reinforced
downstream, since the Stripe Price it publishes to is immutable by Stripe's own rules.

**`pricing_components`** — child rows, immutable with their version, any number per version:

- `kind` — `fixed` | `percentage`
- `cadence` — `one_time` | `recurring`; `period` (`month` | `year`) when recurring
- `amount_cents` (fixed) or `rate` (percentage)
- `currency` — **on the component, not the version**. One currency per component, because a
  component becomes one Stripe Price and is collected by one PaymentIntent or one
  subscription item. A *plan* may mix: setup fee in USD, monthly in CAD is two components,
  two Stripe objects, and is legal. The CHECK is therefore per **(version, cadence)**, not
  per version — Stripe requires every item on one subscription to share a currency, so two
  recurring components in different currencies is unchargeable, while a one-time USD
  component beside a recurring CAD one is fine. Selling *the same* component in several
  currencies is a Stripe multi-currency Price (`currency_options`), not extra components.
- `applies_to` — the metering event type this prices against
- `stripe_price_id` — filled in at publish. The component is the unit that maps one-to-one
  onto a Stripe Price, which is why the split lives here rather than on the version.

The payer-facing line item is generated from the component, not stored on it. A stored label
and a generator are two spellings of the same string that drift apart, which is #292.

Composition is the point. "2% plus $20/month" is two rows; "5% affiliate share, one-time
setup fee, monthly floor" is three; registry's own 2% is one row with `provider_id` =
registry. No count is special-cased and no combination requires code.

**`pricing_schedules`** — replaces `pricing_relationships`, which already carries
provider/consumer/status and needs versioning and effective dating. `provider_id`,
`plan_version_id`, `effective_at`, `ends_at`, `status`. `tenants.platform_pricing_plan_id` is
**dropped**, not kept in sync.

The consumer is `consumer_tenant_id` **plus** a nullable `consumer_user_id`, not one of two.
`consumer_tenant_id` is always set and always FK-enforced: when the consumer is a tenant it
names them, and when the consumer is a person it names the tenant that person belongs to.
`consumer_user_id` NULL therefore means "the consumer is the tenant itself" — which is the
registry→tenant case — and non-NULL means a person within that tenant. No CHECK on
mutual exclusion is needed, because there is no exclusion.

`consumer_user_id` gets **no foreign key**, and the reason is worth stating rather than
rediscovering. Parent users do not live in `registry.users`: `DAO/User.pm:111-118` deletes
`__tenant_slug` from the data and writes to `"$tenant_slug.users"`, so the row that a
schedule would point at is in the tenant's own schema. The existing table already gets this
wrong — `pricing_relationships_consumer_id_fkey` references `registry.users(id)`
(`sql/test-schema.sql:4623`), a constraint no parent consumer could ever satisfy, which is
one more reason nothing has ever written one of those rows. The companion
`consumer_tenant_id` is what makes the unconstrained column safe: it names the schema the
user must be resolved in, so `Entitlement` validates the pair against
`<consumer_tenant>.users` inside the same transaction rather than trusting a bare uuid.

There is deliberately no `consumer_family_id`; see below.

There is deliberately no `consumer_family_id`. A family is an after-school and camp concept,
not a pricing concept — other tenant businesses will not have one, and a third FK would bake
today's vertical into the layer whose entire job is to be agnostic to it. A plan is sold to a
tenant or to a person. Which people share a household is the product's question, answered by
the enrollment, and it is free to change without touching the pricing model.

**`metering_events`** — `provider_id`, consumer FKs, `event_type`, `quantity`,
`amount_cents`, `occurred_at`, `source` reference. Written for every monetizable event
including zero-priced ones — the pillar's literal wording, and the part Stripe cannot do
for us: Stripe only holds events against a meter that already exists, and the whole point
of Pillar 3 is recording volume *before* anyone has decided to charge for it. That is the
half that ships. Forwarding priced events to Stripe as meter events waits for usage-based
pricing, which no component kind here expresses; when it arrives, Stripe does the arithmetic
and raises the invoice, and we add no accrual code. Ours is the record of what happened;
Stripe's is the thing that bills.

**Quote columns on `payments`** — `plan_version_id`, `application_fee_cents`, and the
resolved fee rate, stamped in `_record_intent` (`Payment.pm:206-216`) beside the intent
id. This single change closes four review findings at once: the fee is never recorded,
the rate can be retroactively rewritten, the refund policy follows a tenant between plans,
and "0% because Free" is indistinguishable from "2%".

Plus `stripe_account_id`, which the direct-charge move makes mandatory rather than nice to
have. A PaymentIntent id on a connected account is only retrievable with the `Stripe-Account`
header naming that account; without the column, `Job::ReconcilePayments` cannot look up its
own rows and a refund cannot find the charge it is reversing. It is the one piece of routing
information that is not derivable from the row itself once a tenant has more than one account
in its history.

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

**Which schema these tables live in: `registry`, and only `registry`.**

Registry's multi-tenancy is structural cloning, not shared tables.
`clone_schema` (`sql/deploy/schema-based-multitennancy.sql:344-352`) loops over *every*
`BASE TABLE` in the `registry` schema and issues
`CREATE TABLE <tenant>.<t> (LIKE registry.<t> INCLUDING ALL)`. It is indiscriminate: add a
table to `registry` and the next tenant onboarded gets an empty copy of it.

Left alone, that quietly breaks the central claim of this design. A `pricing_schedules` row
for registry→tenant would live in `registry.pricing_schedules` while one for tenant→family
would land in `acme.pricing_schedules` — the same relation in two physical tables, which is
two code paths wearing one name. The existing code already copes by hand: `RevenueShare.pm`
fully-qualifies `registry.pricing_plans` at `:34`, `:60`, `:94` and `:116` precisely so it
reads the platform's rows and not the tenant's.

So it is stated as a rule rather than left to each query's author. **`pricing_plan_versions`,
`pricing_components`, `pricing_schedules` and `metering_events` live in the `registry` schema
only, are excluded from cloning, and are always referenced fully-qualified.** A schedule is a
relation *between* two parties and belongs to neither one's schema; a tenant's plans are
visible to that tenant by `provider_id`, not by which schema the bytes sit in. `payments` and
`enrollments` stay tenant-schema — those are the tenant's own records, and the quote stamp is
what joins them across the line.

**`pricing_plans` is the exception, and it is the dangerous one.** An earlier draft of this
section asserted the tenant-schema copies were empty clones and specified a migration to drop
them. That was wrong, and acting on it would have deleted every tenant's program pricing.
`<tenant>.pricing_plans` is live, populated, and on the charge path today:

- `sql/deploy/enhanced-pricing-model.sql:79-142` loops over every non-`registry` tenant and
  migrates *rows* — renaming `pricing` to `pricing_plans`, backfilling `plan_type` and
  `requirements`, and inserting a Standard plan beside each early-bird one.
- `DAO/PricingPlan.pm:66-72` deliberately uses the **unqualified** table name, with the
  comment saying so: *"This allows both the registry schema and tenant schemas to store
  pricing plans in their own pricing_plans table."* `find` at `:87-89` does the same.
- The charge path reads it: `Payment.pm:517` → `Session.pm:164-166` →
  `PricingPlan->get_pricing_plans`, resolved against the tenant connection's `search_path`.

The two tables are not even the same shape. `unified-pricing-infrastructure.sql:10` did
`DROP TABLE IF EXISTS registry.pricing_plans CASCADE` and recreated it with `plan_scope`,
`offering_tenant_id` and `pricing_configuration` — while the tenant copies still carry the
`enhanced-pricing-model` shape. A tenant onboarded before that migration and one onboarded
after have structurally different `pricing_plans` tables, and `clone_schema` will keep
handing out the newer one. That is the concrete form of the "two representations" problem
this design exists to end.

So the tenant rows are **migrated, not dropped**: each `<tenant>.pricing_plans` row becomes a
`registry.pricing_plans` row with `provider_id` = that tenant, plus a v1
`pricing_plan_versions` row and its components. That is the same operation Leg 4 already
performs on the registry-schema rows, run once per tenant schema — which is the horizontal
recursion doing its job, not a special case. Only after Leg 8 reads exclusively through
`Entitlement` do the tenant-schema tables get dropped, in Leg 9 with the other deprecated
columns.

`pricing_plans.session_id` survives this. It is not scope and not type — it is the link from
a plan to the product it prices, and it is what makes Resolution step 2 ("the product's own
plan version") resolvable at all. It stays on `pricing_plans`, nullable, and is how a
transactional enrollment quote finds its components when no schedule row governs.

**The exclusion is five loops, not one, and it lands in Leg 4.** `clone_schema` copies
sequences (`:303-339`), tables (`:344-366`), foreign keys (`:369-380`), triggers (`:415-441`)
and views (`:445-457`), and `set_config('search_path', dest_schema, true)` at `:299` means an
unqualified reference inside any of them resolves to the *destination* schema. Every loop
needs the same skip list or the table arrives without its constraints instead of not
arriving. It ships in Leg 4 alongside the tables themselves, not in Leg 7 — a tenant onboarded
between those two legs would otherwise be born with clones nobody expects.

One consequence for the quote stamp: `payments` is a tenant-schema table, so
`payments.plan_version_id` **gets no foreign key** to `registry.pricing_plan_versions`.
`clone_schema`'s FK loop rebuilds constraints against the destination schema, so a
cross-schema FK would be rewritten to point at a `<tenant>.pricing_plan_versions` that must
not exist. It is a plain `uuid` column, and the tenancy invariant test below is what stands
in for the constraint.

### Collection mechanisms

Cadence × kind is four mechanisms. All four ship; one ships in its simple form only.

| Component | Example | Collected by | Status |
|---|---|---|---|
| `fixed` / `one_time` | $150 enrollment; $50 setup fee | PaymentIntent | exists |
| `percentage` / `one_time` | registry's 2%; an affiliate cut | `application_fee_amount` on the PaymentIntent | exists — `RevenueShare` |
| `fixed` / `recurring` | $30/mo membership; Registry Plus $100/mo | Stripe Subscription | exists — `DAO::Subscription` |
| `percentage` / `recurring` | 2% of a family's monthly membership | `application_fee_percent` on the Subscription | **ships** — one parameter |
| — hybrid: percentage *plus* flat | "2% plus $20/month" | `application_fee_amount` from an `invoice.created` handler | **deferred** |

**The earlier draft specified `percentage`/`recurring` wrongly, then over-corrected by
deferring all of it.** The wrong specification called for "a metered Price on the consumer's
subscription, fed by meter events" — that is how a provider *bills* a consumer for usage, not
how a platform takes a cut of someone else's revenue, and the two were conflated. The
over-correction then cut the mechanism entirely, which would have left every tenant→family
membership un-fee'd: the tenant sells a $30/month membership on their own account and Registry
collects nothing. That is a revenue hole, not a deferral.

The pure-percentage case is one parameter and it ships:

```
POST /v1/subscriptions   Stripe-Account: acct_…   application_fee_percent=2
```

Stripe: *"One time each billing period, Stripe takes this percentage of the final invoice
amount, including any bundled invoice items, discounts, or account balance adjustments, as a
fee for the platform."* No handler, no accrual, no meter.

What defers is the **hybrid** — a flat monthly fee, or a percentage *plus* a flat fee.
Stripe's constraint:

> "Application fees on subscriptions must normally be a percentage because the amount billed
> with subscriptions often varies. You can't set a subscription's recurring application fee
> as a flat amount."

Those cases need an `invoice.created` handler writing `application_fee_amount`, and that
amount "overrides any application fee amount calculated with `application_fee_percent`" — the
two do not stack, so the handler computes one number from the Quote. It is deferred for the
same reason `tiered` is: no named consumer. It also carries a cost worth knowing before
signing up for it — *"If Stripe fails to receive a successful response to `invoice.created`,
then finalizing all invoices with automatic collection is delayed for up to 72 hours"* — so
a bug in that handler stalls every tenant's billing, not just the hybrid plans'.

Four Stripe restrictions bind the shipping half and belong in the design rather than in a
Leg 8 surprise:

- **`application_fee_amount` is omitted, never zero.** A Free-tier quote produces no fee
  parameter at all; the code path for "no fee" is absence, which is the same
  absence-versus-zero discipline the resolver enforces one layer up.
- **The platform cannot update or cancel a subscription it did not create**, nor add an
  `application_fee_amount` to an invoice it did not create. Registry must be the creator of
  every tenant→family subscription, which it is — `PriceOps::Schedule` creates them.
- **Only connected accounts with full-Dashboard access can manage their customers'
  subscriptions.** This is a constraint on the account configuration, not on us; see
  "Account configuration" below.
- **Every item on one subscription must share `currency`, `interval` and `interval_count`.**
  The per-(version, cadence) CHECK covers currency; it extends to cover period too.

**Pillar 3 therefore ships as recording, not as billing.** `metering_events` is written
from day one, including for zero-priced events, because the pillar's whole point is holding
volume *before* anyone decides to charge for it and that data cannot be backfilled.
Forwarding those rows to Stripe as meter events is what waits, and it waits for a usage-based
component kind to consume them.

### Account configuration

Stripe deprecated the legacy account types while this design was being written, and Registry
has zero connected accounts — so this is the last moment the choice is free.

> "The information on this page applies only to platforms that already use legacy connected
> account types (Standard, Express, or Custom accounts). If you're setting up a new Connect
> platform, or your integration uses the Accounts v2 API, see the Interactive platform
> guide." — and, on the same page: *"Stripe recommends that you use controller properties
> instead of account types."*

The spec's earlier text named **Standard** accounts throughout, following
`docs/operations/sacp-stripe-connect-onboarding.md:3,11`. Standard is exactly right on the
properties this design depends on — Supported charge types: *Direct only*; Fraud and dispute
liability: *Connected account for direct charges*; Dashboard access: *Full* — but it is the
deprecated spelling of them.

**Recommendation: v1 Accounts with controller properties**, configured to reproduce
Standard's shape (`controller.losses.payments=stripe`, `controller.fees.payer=account`,
`controller.stripe_dashboard.type=full`). Registry keeps every property it is designing
around and stops building on a surface Stripe has marked legacy. Accounts v2 is the further
step and buys nothing this milestone needs.

This is a decision for perigrin, not one this document should make silently, because it is a
liability and onboarding-UX choice as much as a technical one. It changes Leg 3's shape in
one concrete place: **disconnect**. OAuth `/v1/oauth/deauthorize` and the
`account.application.deauthorized` event are Standard-and-OAuth mechanisms — a
controller-properties account returns `no_deauth_on_controlled_account` and uses the
rejection API instead. Whichever is chosen, the disconnect bullet under "Money movement"
describes the flow; only the endpoint differs.

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

**Refunds resolve backwards, not forwards.** A refund prices an event that already happened,
so `refund_application_fee_for_tenant` reads the terms stamped on the payment row rather
than quoting afresh. `Payment.pm:114` resolves from the tenant's *current* plan today, which
is why moving a tenant between plans rewrites the refund policy of every charge they have
ever taken. Quoting a refund is the same bug in a new resolver; reading the stamp is the fix.
This is the one place the quote is a read rather than a write, and it is the reason the quote
columns exist.

### Money movement (not PriceOps)

- **Webhook atomicity.** Claim and processing collapse into one transaction: BEGIN,
  `INSERT ... ON CONFLICT DO NOTHING`, process, COMMIT. A crash rolls the claim back with
  the work and Stripe's retry heals it for free — strictly less code than the current
  claim-at-`Webhooks.pm:46-50` / release-in-`catch`-at-`:85` pair. Add `processed_at` to
  `registry.webhook_events`.
- **One transaction means one connection, which the handler does not currently have.**
  This is #247, and it is a prerequisite of the bullet above rather than a follow-up to it.
  `Webhooks.pm:112` reaches the tenant schema via `$dao->connect_schema($slug)`, and
  `DAO.pm:105` implements that as `blessed($self)->new(url => $url, schema => $schema)` — a
  fresh `Registry::DAO`, a fresh `Mojo::Pg` (`DAO.pm:36-38`), a fresh connection pool. The
  claim is written on one connection and the payment row on another, so no BEGIN can span
  them and a crash between the two leaves a claimed event that was never processed: the
  paid enrollment Stripe will not redeliver.

  The fix is to stop switching connections. `Mojo::Pg` sets `search_path` per connection at
  connect time, which is why a different schema means a different pool; but a *transaction*
  can set its own with `SELECT set_config('search_path', $1, true)` — `SET LOCAL` semantics,
  reverted at COMMIT, and taking a bind parameter, so the slug from
  `$intent->{metadata}{tenant_slug}` never reaches the SQL text. The handler resolves the
  slug to a tenant row first (which is the validation), then sets the path for the life of
  the transaction. The pricing tables are registry-schema and fully-qualified regardless, so
  nothing else has to move.

  Two properties of `set_config(..., true)` are load-bearing and easy to get wrong. It is
  `SET LOCAL`, so **outside a transaction it silently does nothing** — no error, just a
  handler quietly reading the wrong schema. And it reverts at COMMIT, so a nested `begin`
  inside the handler would end the setting early. The rule is one `begin` at the top of
  `stripe()` and no other transaction below it, asserted by the Leg 0 tests.

  Set the path to **`<tenant>, public`**, matching what `connect_schema` produces
  (`DAO.pm:39`: `search_path([$schema, 'public'])`) rather than widening it to include
  `registry`. Widening looks harmless and is not: an unqualified `pricing_plans` would then
  fall through to the registry table when the tenant's is absent, which converts a loud
  missing-table error into a silent read of another provider's plans. The pricing tables are
  reached by their full name; nothing needs the fallback.
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
- **Charge model.** Tenant→family moves to direct charges on the tenant's connected
  account, per "Whose Stripe account" above. `Payment.pm:64-96` stops sending
  `transfer_data[destination]` and `on_behalf_of`; `application_fee_amount` is unchanged.
  The header itself is three lines in one place — `Service::Stripe::_request_async` builds
  headers at `:28-32` and every method routes through it. The Payment Element is initialised
  with `stripeAccount` (`templates/summer-camp-registration/payment.html.ep:144`), which
  uses the *platform's* publishable key, so no per-tenant key is needed. Families become
  Customers on the tenant's account. Registry→tenant stays on the platform account and does
  not change.

  There is no `Stripe-Account` support in `lib/` today — the string appears nowhere — so this
  is new plumbing, not a parameter change. It belongs in
  `Service::Stripe::_request_async` (`:28-32`) as an optional per-call account, because every
  method already routes through it and adding it anywhere else means adding it repeatedly.
- **Recurring tenant→family collection is part of this milestone, not assumed by it.** The
  acceptance criterion enrolls a family against a monthly membership, and nothing in the
  current code can create that subscription: `Subscription.pm:118-158` builds inline
  `price_data` on the **platform** account with no `Stripe-Account` and no `application_fee_*`.
  `PriceOps::Schedule` creating a direct-charge subscription on the provider's account —
  `Stripe-Account`, a published Price from Leg 6, `application_fee_percent` from the quote — is
  the missing half, and it lands in Leg 8 with the resolver that feeds it. Without it the
  milestone gate cannot pass no matter how good the model is.
- **Refunds move with the charge model.** `_refund_connect_params` (`Payment.pm:109-119`)
  sends `reverse_transfer => 'true'`, which does not exist for a direct charge — there is no
  transfer to reverse. It goes; `refund_application_fee` stays. `t/dao/refund-application-fee.t`
  asserts `reverse_transfer` at `:271, :318, :346, :375, :416` and is re-cut in the same leg.
  Refunds are a requirement of this milestone, not a follow-up: the charge model cannot move
  without them, and #286 lands here. The platform refunds a direct charge with its own secret
  key authenticated as the connected account, so the mechanism carries over unchanged. Note
  what Stripe says about the flag we are keeping: application fees are *not* automatically
  refunded, and if the platform does not refund one explicitly "the connected account — the
  account on which the charge was created — loses that amount." A wrong answer from
  `refund_application_fee_for_tenant` costs the tenant money, not us, which is why it reads a
  stamped quote rather than a mutable plan. One behavioural difference to carry into the
  re-cut suite: a direct-charge refund can come back `pending` when the connected account's
  balance will not cover it, where a destination-charge refund on the platform's own balance
  normally would not. `succeeded` is not the only success, and a test asserting it is a test
  that will go red in production rather than in CI.
- **A single Stripe client.** `Registry::Client::Stripe` (198 lines) is deleted. Twenty-one
  of its twenty-six methods are pass-through to `Registry::Service::Stripe` — seventeen thin
  delegations plus four error predicates — its remaining logic is
  installment-specific, and its only two callers — `PriceOps/ScheduledPayment.pm:18` and
  `PriceOps/PaymentSchedule.pm:19` — are already deleted by Leg 1. `Service::Stripe` becomes
  the sole client. It is not renamed: roughly ten test files monkey-patch it by
  fully-qualified name, and that is churn for a noun.
- **Disputes.** A `charge.dispute.created` handler plus tenant-facing tooling. See
  "Dispute resolution" below — it is a requirement of this milestone, not an alert.
- **A tenant who disconnects must stop paying us, and the webhook is too late to do it.**
  Stripe: *"If the subscription was created with an `application_fee_percent`, the application
  fee continues to be collected by the platform after disconnect. Remove the
  `application_fee_percent` from the Subscription **before** a connected account disconnects
  from your platform."* An earlier draft answered this with an
  `account.application.deauthorized` handler that clears the fee. That cannot work:
  *"After revocation, the account can't be accessed by your platform in the Dashboard or
  through the API."* By the time the event arrives, every call the handler wants to make is
  already refused.

  So it splits by who initiates, and only one half is ours to fix.

  **Registry-initiated** is the path we control and the one to build: a "disconnect from
  Registry" action that ends the tenant's schedule rows, clears `application_fee_percent`
  from every subscription on that account *while we still have access*, and only then calls
  the revoke endpoint. Ordering is the whole feature.

  **Account-initiated** — the tenant clicks Remove in their own Dashboard — leaves us no
  window at all. The `account.application.deauthorized` handler still earns its place, but
  its job is bookkeeping and honesty, not collection: end the schedule rows, mark the tenant
  disconnected, and notify them that Stripe has left our fee on their subscriptions and
  that they can clear it themselves (*"After disconnect, a connected account can clear the
  `application_fee_percent` parameter from existing Subscriptions through the API"*). A
  platform that keeps quiet here is one that keeps collecting from someone who left.

  Also worth recording, because it reads as a bug when discovered live:
  *"Subscriptions aren't automatically canceled when you disconnect from the platform."*
  Families stay subscribed to a tenant who left Registry. That is correct — the tenant is the
  merchant and the service is theirs — but it means our enrollment records go stale silently,
  and the handler should mark them rather than let a dashboard imply we still know.
- Plus #284, #289, #293, and the tenant-subscription lifecycle fix. Registry→tenant subscriptions
  are platform-account objects and still need `$tenant_id` passed through to
  `create_subscription_with_config` (`TenantPayment.pm:340-344` vs `Subscription.pm:118`)
  so the five handlers that bail on `return unless $tenant_id` can run.

  **Those handlers must not be reached by tenant→family events**, and the obvious fix would
  reach them. `Subscription.pm:263,277,294,314,327` each resolve
  `$subscription->{metadata}{tenant_id}` and then call `update_billing_status`
  (`:188-204`), which does `UPDATE registry.tenants SET billing_status = ?`. Under direct
  charges a family's membership renewal produces the same `customer.subscription.updated` and
  `invoice.payment_*` event types — so feeding these handlers a tenant id derived from the
  event's `account` field, as an earlier draft proposed, would let a parent's failed card mark
  the *tenant* `past_due` and a cancelled membership mark them `cancelled`. The `account`
  field identifies the **provider**, never the consumer. The dispatch rule is therefore the
  envelope, not the metadata: an event carrying an `account` is a tenant→family event and
  routes to the enrollment path; an event with no `account` is a platform-account event and is
  the only kind allowed to touch `billing_status`. `billing_status` also gets at least one
  reader — today `update_billing_status` has no caller in `lib/` at all, only
  `t/dao/stripe-subscription.t:146,157`.

### Dispute resolution

Under direct charges the dispute belongs to the tenant, so the tenant needs tools — not a
notification that something bad is happening in an account they have to go elsewhere to
defend. Registry's admin dashboard grows a disputes surface.

**We do not build a dispute evidence form.** Stripe ships Connect embedded components that
do exactly this, mounted inside our own page: `disputes_list` displays the account's
disputes and, with the `dispute_management` feature enabled, lets the tenant **submit
evidence, counter, or accept** a dispute without leaving Registry. `disputes_for_a_payment`
does the same beside a single payment. Server-side this is one AccountSession call with
`components[disputes_list][enabled]=true` and
`components[disputes_list][features][dispute_management]=true`; client-side it is ConnectJS
and `stripeConnectInstance.create('disputes-list')`. The translator rule applies to UI as
much as to billing: anything Stripe already does, we call rather than rebuild.

What Registry adds is the half Stripe cannot see. A "services not rendered" dispute against
an after-school program is answered by the enrollment record, the attendance rows, and the
message history — data that lives here and nowhere else. So the page is the Stripe component
plus, per dispute, a link to the enrollment it came from and the evidence Registry can
assemble from its own tables. That join is possible because the quote stamp on the payment
row (`plan_version_id`, fee, rate) makes a Stripe charge id resolvable back to what was sold.

Three pieces, all in Leg 12:

1. **Route and page.** `$admin->get('/dashboard/disputes')` following the existing pattern at
   `Registry.pm:676-703`, a method on `Controller::AdminDashboard`, a template in
   `templates/admin_dashboard/`. Admin pages here are plain controller-to-template, not
   workflow-driven, so this is the small kind of change.
2. **AccountSession endpoint.** A short-lived session scoped to the requesting tenant's
   connected account. It is an authorization boundary: the session must be minted from the
   tenant on the session, never from a parameter.
3. **`charge.dispute.created` webhook → alert.** Disputes have a hard response deadline and
   nobody watches a dashboard. The handler writes the dispute reference against the payment
   row and notifies the tenant with the deadline. This arrives on the Connect endpoint that
   Leg 3 registers.

Embedded components are documented as "most compatible with Connect integrations that accept
direct charges" — dispute management for destination charges needs an extra opt-in feature
flag and only covers `on_behalf_of` charges. This is independent support for Leg 3 rather than a
new argument.

## What gets deleted

Installments are cut. ~3,700 lines across `lib/` and `t/`, the `Webhooks.pm:69-71,204-289`
branch, and forward migrations for `payment_schedules` and `scheduled_payments`. Close
#295 and #279 as won't-do. Rationale: unreachable for eleven months, two independent
breaks from working (an orphaned workflow step *and* a registry-scoped webhook classifier
that cannot see tenant-schema rows), drifted from `Payment.pm` on four separate fixes, and
never offered to a single parent. It also frees the name `Schedule`, which
`PriceOps::PaymentSchedule` currently occupies for an unrelated meaning.

`Registry::Client::Stripe` goes with them, in the same leg and for the same reason: it is a
198-line delegation wrapper whose only callers are those two modules. Registry ends the
milestone with one Stripe client.

Also deleted: `t/dao/pricing-plan-clean-architecture.t` (#296),
`t/e2e/installment-payment-enrollment.t` and
`t/controller/admin-installment-payment-dashboard.t` (both DAO CRUD misfiled under names
that make the feature read as covered), the orphaned discount configuration in
`templates/pricing-plan-creation/requirements-rules.html.ep` and `RequirementsRules.pm:46-90`,
and `Family::sibling_discount_eligible`.

`PriceOps/UnifiedPricingEngine.pm` and `PriceOps/PricingRelationships.pm` are deleted **in
Leg 7, not before** — they are the only code in `lib/` that can write a
`pricing_relationships` row, so they must be replaced rather than removed ahead of the
replacement. `DAO::PricingRelationshipEvent` dies with them. Close #76.

## Sequencing

Legs are renumbered from the previous draft: the old 2a/2b lettering is gone, the old Leg 2
is split in two, and the old Legs 6 and 7 collapse into one recording-only leg. Estimates are
engineering days for one person and are ranges because several depend on how much of the E2E
suite has to be re-cut rather than extended.

| Leg | Content | Depends on | Days |
|---|---|---|---|
| 0 | Webhook atomicity in one transaction on one connection (**#247** is a prerequisite, not a follow-up); `update` → `save` on money paths | — | 2-3 |
| 1 | Safe deletions: installments, `Client::Stripe`, misfiled tests, #296, discount form | — | 2-3 |
| 2 | **#294**: collapse `registry-platform` into `registry`; retire the all-zeros UUID as a provider identity | 1 | 1-2 |
| 3 | Charge model: **account configuration decided**; tenant→family becomes direct charges; `Stripe-Account` in `Service::Stripe`; refunds lose `reverse_transfer`; Payment Element `stripeAccount`; Customers on the tenant's account; Connect webhook endpoint and its secret; Registry-initiated disconnect + `account.application.deauthorized` bookkeeping | 0, 1 | 6-8 |
| 4 | `pricing_plan_versions` / `pricing_components`; `pricing_plans` gains `provider_id`, keeps `session_id`; migrate registry **and every tenant schema's** plans to v1; **`clone_schema` exclusion across all five loops**; `plan_scope` and `plan_type` kept nullable and dual-written | 2 | 5-7 |
| 5 | Rewrite the `pricing-plan-creation` workflow onto the version/component vocabulary | 4 | 4-6 |
| 6 | Publish projection: version → Stripe Product, component → Stripe Price **on the provider's account**; ids recorded; `Subscription.pm` stops building inline `price_data` | 3, 4 | 3-4 |
| 7 | `pricing_schedules`; migrate `pricing_relationships` + `platform_pricing_plan_id` (**column kept nullable and dual-written**); delete the two dead modules | 4 | 3-4 |
| 8 | `Entitlement` + `Quote`; rewire the charge; **`Schedule` creates direct-charge subscriptions with `application_fee_percent`**; repoint `PricingPlanSelection` and `GenerateEvents`; delete `calculate_enrollment_total`; refuse-not-zero; `RevenueShare` becomes a wrapper | 6, 7 | 5-7 |
| 9 | Quote columns on `payments` incl. `stripe_account_id`; fee recorded; `DAO/AdminDashboard.pm:36` corrected; **drop the deprecated columns and the tenant-schema `pricing_plans`** | 8 | 2-3 |
| 10 | `Metering`: record every monetizable event including zero-priced ones; drop `billing_periods` | 7 | 1-2 |
| 11 | Pillar 5: `./registry pricing` CLI + CHECK constraints; retire hand-typed SQL seeds | 4, 5 | 2-3 |
| 12 | Dispute resolution: admin page, embedded components, AccountSession, `charge.dispute.created`; `Job::ReconcilePayments`; subscription lifecycle envelope dispatch | 0, 3, 9 | 3-5 |

**37 to 55 days.** That is the honest number, and it is the argument for shipping legs
rather than a milestone: 0, 1, 2 and 3 are independently valuable and land inside two
weeks. Leg 3 is the one with a deadline attached — it must merge before the first tenant
onboards — and it does not depend on any of the pricing model work.

**Legs 4 and 7 do not drop the columns they replace.** `RevenueShare.pm:58-64,114-120`
selects the platform plan by `plan_scope='platform'` and `:35,95` joins on
`tenants.platform_pricing_plan_id`. Both are live on the charge path, and their replacement
does not exist until Leg 8. Dropping either when its successor table lands would break
collection for four legs. So both stay nullable and dual-written from the leg that
supersedes them until Leg 9 removes them — one migration later than feels tidy, which is
the correct trade when the alternative is an unpriced enrollment.

The same rule covers the tenant-schema `pricing_plans` tables, and there the stakes are
higher because those rows are a tenant's actual program prices rather than a nullable
pointer. Leg 4 copies them up into `registry.pricing_plans` with `provider_id` set and
leaves the originals in place, still read by `PricingPlan->get_pricing_plans` through the
tenant `search_path`. Only Leg 9, after `Entitlement` has been the sole read path for a leg,
drops them. **The `clone_schema` exclusion moves to Leg 4** for the same reason in the other
direction: it must land with the tables, or a tenant onboarded in the gap between Leg 4 and
Leg 7 is created with clones of the new tables and immediately violates the invariant.

Leg 0 ships alone and first: it can lose a paid enrollment today and depends on nothing
else here.

**Why the quote stamp is not Leg 1.** It is the change that closes the most money bugs —
the unrecorded fee, the retroactive rate, the refund policy that follows a tenant between
plans — and an outside reader is right to ask why it sits at 9. Because a stamp records
what a resolver decided, and stamping today's resolver would preserve today's answer:
`RevenueShare` reading a mutable plan through a nullable pointer. The bug is not that the
rate goes unrecorded, it is that the rate is not a fact until a version makes it one. A
stamp without an immutable version behind it records the same ambiguity with a timestamp
on it. Legs 4 through 8 exist to give Leg 9 something true to write down.

**Leg 2 is nearly free if it goes here and expensive anywhere else.** The all-zeros UUID
appears in exactly five places in `lib/` — and every one of them is in code this milestone
already deletes or rewrites: `PricingRelationship.pm:140` and `UnifiedPricingEngine.pm:26`
die in Leg 7, `PricingPlanBasics.pm:70` and `RequirementsRules.pm:186` are inside the
authoring workflow Leg 5 rewrites, and `PricingPlanSelection.pm:14` (the `PLATFORM_UUID`
constant) is in the tenant-signup workflow Leg 8 repoints. The SQL side is larger —
`unified-pricing-infrastructure.sql` alone holds
seven — but those are deployed migrations that are not edited, only superseded. Collapsing
before Leg 4 means the five live sites are corrected once, as part of a rewrite that was
happening anyway. Collapsing after means Leg 4 migrates every plan to a `provider_id` of
all-zeros and Leg 7 migrates them again.

Two traps in that migration. The `registry` tenant is not created by any migration — it
exists only in seed data, while `registry-platform` *is* seeded by
`unified-pricing-infrastructure.sql:82` (`sql/test-schema.sql:2514`) — so the migration
resolves the target by slug and must create it if absent rather than assuming it. And the
all-zeros UUID does double duty as a system-user sentinel: the three `message_templates`
rows seeded at `sql/deploy/parent-communication-system.sql:165,180,197` use it as
`created_by`, a column declared `uuid NOT NULL` with **no foreign key at all** — not to
`users`, not to anything. So nothing would object if the migration repointed them at the
registry *tenant* id, and the value would be silently meaningless. Leg 2 must leave them
alone; giving them a real system user is its own issue.

**Leg 3 is the leg with the most surface area, but it is not a cutover.** An earlier draft
called it "the only leg that changes a path already carrying real charges." That was wrong:
no connected account has been onboarded. Every tenant row has `stripe_connect_account_id`
NULL (`sql/test-schema.sql:2513+`), no `acct_` id appears anywhere in `sql/`, and
`docs/operations/sacp-stripe-connect-onboarding.md` is a runbook for a future operator rather
than the record of a completed setup. So there is no migration of live accounts, no tenant
whose receipts change identity overnight, and no dispute in flight. Direct charges are simply
*the* charge model, adopted before there is anything to convert.

What remains real is the surface: it re-cuts the money-path E2E suite rather than extending
it, it touches the Payment Element, and it needs the Connect endpoint below. It still gets
its own branch with the re-cut suite as its gate, and it still sits early, because every plan
published to a connected account in Leg 6 assumes it and retrofitting afterwards would mean
publishing the same Prices twice. It depends on Leg 1 only because deleting installments is
what frees `Registry::Client::Stripe`.

One thing to fix while re-cutting the suite: `t/lib/Test/Registry/StripeConnect.pm:86-91`
creates a **Custom** account requesting `card_payments` and `transfers`, while production
onboards **Standard** accounts (`docs/operations/sacp-stripe-connect-onboarding.md:3,11`).
The suite has been exercising a different account type than production will use, and
`transfers` is the destination-charge capability. The fixture moves to whatever "Account
configuration" above settles on, requesting `card_payments` only — the fixture and the
runbook must name the same thing, and today they do not.

**Leg 3 needs a Connect webhook endpoint before it needs any code.** Events from a connected
account arrive at a Connect endpoint, which carries its own signing secret. Registry has
exactly one, read from `$ENV{STRIPE_WEBHOOK_SECRET}` at `Webhooks.pm:14` and `Payment.pm:141`
(and at `Client/Stripe.pm:18`, which Leg 1 deletes). Until a second endpoint and secret exist, a direct charge
succeeds at Stripe and Registry never hears about it — the same failure mode as the webhook
defect Leg 0 fixes, reintroduced by configuration. Register the endpoint and add the secret
first; the code is the easy half.

The tenant lookup Leg 3 needs is already written: `Webhooks.pm:148-162` resolves a tenant from
`stripe_connect_account_id` for `account.updated`. Payment events reuse it rather than
inventing one.

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

Plus one tenancy invariant, because `clone_schema` is silent when it is wrong: onboard a
tenant, then assert that the tenant's schema contains none of `pricing_plan_versions`,
`pricing_components`, `pricing_schedules` or `metering_events`, and that a schedule written
for that tenant is readable from a DAO connected to its schema. Both halves are needed — the
first catches the exclusion list rotting as tables are added, the second catches a query that
forgot to qualify. It asserts nothing about `<tenant>.pricing_plans`, which legitimately
exists and holds rows until Leg 9; the test flips to include it in that leg, and the reason
is written down here so the flip is not mistaken for the exclusion list having been wrong all
along.

Plus the money-movement tests: a webhook killed mid-processing leaves no claim, and one
killed after the claim but before the payment row leaves neither (Leg 0 — the second
assertion is the one that fails today, and it is the whole reason #247 moved into Leg 0);
a `RevenueShare` die surfaces through the charge as a readable error with no second
payment row and no spent idempotency token — twenty lines added to
`t/dao/payment-intent-destination-charge.t`, closing a gap the review found where all five
die paths are unit-covered and none is covered through a request. That file is renamed and
re-cut in Leg 3, since it asserts the destination-charge parameters by name.

And two for the dispute surface, both security-shaped rather than feature-shaped: an
AccountSession is minted only for the connected account of the tenant on the session — a
request naming another tenant's account is refused, not served — and a tenant with no
connected account gets an empty state rather than an error or another tenant's disputes.

And the acceptance test above, which is the milestone gate. It needs the CLI from Leg 11 to
author the plan and the subscription creation from Leg 8 to collect against it, so it lands
last of all — after both, not with either.

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
   `pricing_relationships`. They go in Leg 7, with their replacement.
4. The review filed #296 as test hygiene. It is architectural: that test is the guard for
   the relationship-agnostic-plans invariant, and the invariant was violated by a later
   migration while the guard sat dead.
5. Three issues in the money cluster are already fixed and should be closed rather than
   scheduled: **#267** (`RevenueShare.pm:35` resolves from the tenant's plan; `0ec723f`→`10932e3`),
   **#281** (`_to_cents` no longer exists anywhere in `lib/`), **#288** (`TenantPayment.pm:145`
   passes `amount_cents` into `monthly_amount` → `Subscription.pm:125` `unit_amount`).
   #288 is still labelled `blocker`/`critical-impact`.

## Out of scope

- **`tiered` pricing.** Not in the `kind` vocabulary. It is a fourth collection mechanism with
  no named consumer; adding a `kind` later is an append, which is what an append-only model is for.
- **Hybrid application fees** — a flat recurring platform fee, or a percentage *plus* a flat
  fee, which Stripe can only express through an `invoice.created` handler writing
  `application_fee_amount`. Same test as `tiered`: no named consumer. Note this is narrower
  than an earlier draft, which deferred all of `percentage`/`recurring` and thereby left every
  tenant→family membership with no platform fee at all. The pure-percentage case is
  `application_fee_percent`, one parameter, and it ships.
- **Stripe meter-event forwarding**, and with it usage-based pricing. `metering_events` is
  written from day one; only the forwarding waits, because no component kind here prices
  against a meter.
- **Admin UI for authoring platform plans.** Pillar 5 is satisfied by `./registry pricing`
  plus constraints. UI when a human who is not perigrin needs to author a plan.
- **Sales tax.** No code. Merchant of record is no longer open — direct charges make the
  tenant the seller unambiguously — but what that obliges them to collect is theirs to
  answer and ours to document, not to compute.
- **The drop-approval workflow bug.** `ProcessAdminDropDecision.pm:33` advances one step of
  six while `templates/admin-drop-approval/complete.html.ep:7` reports success. An
  operator-trust bug, unrelated to pricing; it gets its own issue now.

## Decisions

The four questions this design opened are answered.

1. **No `consumer_family_id`.** A family is an after-school and camp concept; other tenant
   businesses will not have one, and a third FK bakes today's vertical into the layer whose
   job is to be agnostic to it. Two consumer FKs, tenant or user. See "Data model" above.
2. **Collapse `registry-platform` into `registry`** — one concept of the platform tenant, not
   two half-concepts in a coat. Scheduled as Leg 2 — before the model tables rather than
   alongside the schedule migration — for the reasons under "Sequencing". Closes #294.
3. **No existing onboarded tenants**, and there will be none until payments are solid. This
   removes the Leg 3 cutover entirely; it is adoption, not migration. Verified against the
   repo: `stripe_connect_account_id` is NULL for every seeded tenant and no `acct_` id
   appears in `sql/`. The consequence is that **Leg 3 should merge before the first tenant
   onboards** — the cheapest moment to change the charge model is the one we are in, and it
   does not recur.
4. **One currency per component; a plan may mix.** A component is one Stripe Price collected
   by one PaymentIntent or one subscription item, so it is single-currency by construction.
   A plan combining a USD setup fee with a CAD subscription is two components and two Stripe
   objects, and is legal. The CHECK lands per (version, cadence) rather than per version,
   since Stripe requires all items on one subscription to share a currency.

A second review round changed four more things, recorded here so the reasoning is not lost:

5. **The new pricing tables are registry-schema only and excluded from `clone_schema`.** The
   design's "one relation, one code path" claim was silently false under a cloning
   multi-tenancy that copies every base table into every tenant schema. Stated as a rule,
   with an exclusion list and a tenancy invariant test, rather than left to each query's
   author to remember to qualify. The exclusion covers `pricing_plan_versions`,
   `pricing_components`, `pricing_schedules` and `metering_events` — **not** `pricing_plans`,
   which is live in every tenant schema and is handled separately by (9). See "Data model".
6. **`percentage`/`recurring` was specified wrongly.** A metered Price is how a provider bills
   a consumer for usage, not how a platform takes a cut. Stripe's actual constraint — no flat
   recurring application fee; `invoice.created` → `application_fee_amount`, which overrides
   rather than stacks with `application_fee_percent` — is recorded. The correction, not the
   mechanism, was what needed fixing: see (12), which un-defers the pure-percentage case.
7. **#247 moved into Leg 0 as a prerequisite.** One transaction requires one connection, and
   `connect_schema` builds a second pool. The atomicity Leg 0 promised was not achievable as
   written. The fix is `set_config('search_path', $1, true)` inside the transaction rather
   than a second DAO.
8. **Deprecated columns outlive their replacements by four legs.** `plan_scope` and
   `tenants.platform_pricing_plan_id` stay nullable and dual-written until `Entitlement`
   ships in Leg 8, dropped in Leg 9. Dropping them when their successor *table* landed would
   have broken collection with no resolver to fall back on.

A third round found that two of those four corrections had over-shot, and turned up five
things the earlier rounds had not looked for:

9. **`<tenant>.pricing_plans` is live, and (5) very nearly deleted it.** The second round
   asserted the tenant-schema copies were empty clones and specified a migration to drop
   them. That was wrong. `enhanced-pricing-model.sql:79-142` migrated *rows* into every
   tenant schema, `PricingPlan.pm:66-72` deliberately uses the unqualified table name, and
   the charge path reads it through `Payment.pm:517` → `Session.pm:164-166`. Acting on the
   earlier text would have deleted every tenant's program pricing. The rows are migrated up
   to `registry` in Leg 4 and the tenant tables dropped in Leg 9, once nothing reads them.
   The two tables are not even the same shape — `unified-pricing-infrastructure.sql:10`
   recreated the `registry` copy with columns the tenant copies never got — so tenants
   onboarded before and after that migration differ structurally, and the migration has to
   handle both.
10. **`pricing_plans.session_id` is kept.** It is neither scope nor type: it is the link from
    a plan to the product it prices, and without it Resolution step 2 has nothing to resolve
    against. It was nearly swept up with the other deprecated columns.
11. **`pricing_schedules` gets `consumer_tenant_id` plus an unconstrained
    `consumer_user_id`.** Parent users do not live in `registry.users` — `User.pm:111-118`
    writes them to `"$tenant_slug.users"` — so a FK from a registry-schema table to a parent
    is not expressible in Postgres. The existing `pricing_relationships_consumer_id_fkey`
    already gets this wrong; no parent consumer could ever satisfy it. The tenant FK carries
    the referential integrity that can be enforced; the user column is validated in code.
12. **The pure `percentage`/`recurring` case ships.** (6)'s deferral was an over-correction:
    it would have left every tenant→family membership with no platform fee at all, which is
    a revenue hole rather than a deferral. A flat percentage of a recurring charge is one
    Stripe parameter — `application_fee_percent` on the Subscription. Only the hybrid
    (percentage plus a fixed recurring amount) waits, because that is the case needing the
    `invoice.created` handler.
13. **Disconnect must be Registry-initiated.** The `account.application.deauthorized` handler
    added last round cannot work: Stripe revokes API access *before* the event is useful, so
    every call the handler wants to make is already refused. Fees are cleared while we still
    have access and revocation follows — ordering is the whole feature. The account-initiated
    path is bookkeeping and a notification, because subscriptions are not canceled by a
    disconnect and their fees are no longer ours to clear.
14. **Account configuration is an open decision for perigrin.** Stripe has deprecated
    Standard/Express/Custom for new platforms. The recommendation is v1 accounts with
    controller properties, but it is a liability and onboarding-UX choice as much as a
    technical one, and it gates Leg 3. See "Account configuration".
15. **Creating the direct-charge subscription is work in this milestone, not an assumption
    of it.** `Subscription.pm:118-158` builds inline `price_data` on the *platform* account
    with no `application_fee_percent`; nothing today can create the recurring tenant→family
    charge the acceptance criterion describes. `PriceOps::Schedule` doing so lands in Leg 8.
    Without it the gate cannot pass, and the omission was invisible because every other leg
    described a table or a rewrite rather than a missing capability.

## Follow-ups this design creates

Not blockers, but they exist because of decisions made here and should not be discovered later.

- **A customer cannot hold two active subscriptions in different currencies.** Mixed-currency
  plans are legal per (4), but a consumer already on a CAD subscription cannot be given a USD
  one by the same provider. The resolver should refuse at quote time with a readable message
  rather than let Stripe reject at collection. Worth a test in Leg 8, where the resolver lands.
- **`message_templates.created_by` uses the all-zeros UUID as a system-user sentinel** in a
  column with no foreign key. Out of scope for Leg 2, which only retires the *tenant*
  identity, but it leaves the literal in the codebase — and an unconstrained `created_by`
  will accept any uuid, including a tenant id, without complaint. Its own issue: a real
  system user, and the FK that would have caught this.
- **Standard accounts can change their own payment-method settings** from their Stripe
  Dashboard. Under direct charges that is their right, and it means the payment methods a
  family is offered are not wholly ours to determine. Document it; do not fight it.
