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

The third arm is a modelling claim only, and it is worth saying which half of it this
milestone actually delivers. A tenant→affiliate plan version is expressible in the model
the moment `provider_id` is a real column — that costs nothing extra. *Collecting* it is a
different question, because the collection mechanism this design chooses for tenant→family
is the platform's application fee on a direct charge, and that fee is Registry's. A tenant
paying a referrer out of the same charge is not another application fee on top of ours;
whatever it is — a Stripe Transfer from the tenant's balance, an off-Stripe arrangement —
it is not designed here and has no consumer asking for it. The recursion this milestone
proves is registry→tenant and tenant→family through one code path. The affiliate arm is
evidence the shape generalizes, not scheduled work.

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

1. The test shells out to `./registry pricing` with a plan shape no current code path
   assembles — a monthly membership on a connected account — and the command exits zero.
2. It enrolls a family against the resulting plan through the ordinary enrollment path and
   asserts a Stripe subscription exists **on the tenant's account** with the expected amount,
   currency and interval, **carrying `application_fee_percent`**, and that one invoice has
   settled with a non-zero `application_fee_amount`.
3. It asserts the plan's name and slug appear in no file under `lib/`, `workflows/`,
   `templates/` or `sql/` — the grep that stands in for "no code change," and the same shape
   as the `price_data` assertion under "Testing". A plan whose name has to be taught to the
   code is a plan that failed Pillar 1.

Point 2 is written that way because the two obvious weaker assertions both pass while the
milestone has failed. A subscription created with `trial_period_days`
(`Subscription.pm:126`) exists, has the right amount, currency and interval, and has moved
no money; and a subscription with no `application_fee_percent` collects for the tenant and
nothing for us, which is the exact revenue hole correction (12) exists to close. Existence
is not collection.

**The test lives in `t/stripe-live/`, and the milestone gate is that workflow rather than
`make test`.** The main suite runs with `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key`
(`.github/workflows/ci.yml:129`) and cannot reach Stripe, so an acceptance test filed under
`t/e2e/` would either skip or assert against nothing. A gate that skips is not a gate.

The honest gap: no test written today can prove that a plan shape *invented tomorrow* needs
no code. Point 3 is the closest mechanical proxy and it is a proxy — and it measures only
the axis that works. See "Collection mechanisms": composing existing component kinds needs
no code; a genuinely new *kind* is a code change by construction, and no grep detects the
difference. What closes the gap is the second such test, written when a real second plan
shape is wanted, and it costs whatever it costs — that cost being the actual measurement.

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
| `PriceOps::Model` | 1 | Plans belong to a provider. Append-only, immutable published versions and their components. Publishing projects the version into a Stripe Product and one Price per component, recording the ids. Exposes `publish_version` and a catalog read — see below; the CLI is a caller, not the API. |
| `PriceOps::Schedule` | 2 | provider → consumer → plan version, effective-dated. Creates the collecting Stripe object for recurring components. |
| `PriceOps::Metering` | 3 | Every monetizable event, including those currently priced at zero. Forwarding to Stripe as meter events is deferred with usage-based pricing; recording is not. |
| `PriceOps::Entitlement` | 4 | Sole read path. Resolves Schedule → Model, returns a Quote. Never touches Stripe. Callers never name a plan. |
| — | 5 | Not a module: `./registry pricing` CLI plus CHECK constraints that make an invalid plan unauthorable. `Registry::Command::*` establishes the shape, though not uniformly — `schema.pm:24`, `template.pm:20` and `workflow.pm:128` take `run($cmd, $schema, @args)` while `tenant.pm:20` omits the schema and `workflow_job.pm:37` is a plain `sub`. Follow the three-of-five majority; the schema argument is the provider identity. |

**The existing authoring workflow is in scope and is the larger half of Pillar 1.** Dropping
`plan_scope`, `plan_type` and `pricing_model_type` invalidates the five step classes of
`workflows/pricing-plan-creation.yaml:13,18,23,28,33` — `PricingPlanBasics.pm:18,20,47,49`,
`PricingModel.pm:17`, `ResourceAllocation.pm:133`, `RequirementsRules.pm:145`,
`ReviewActivatePlan.pm:102-105,169-174` — **862 lines of step classes plus 1,412 lines of
`templates/pricing-plan-creation/`**, and the `pricing_plans_plan_scope_check` constraint. An
earlier draft said 1,028 lines, which double-counted `PricingPlanSelection.pm` (excluded in
the next paragraph) and ignored the templates entirely; the template half is the larger one.
If the workflow survives it is rewritten to author versions and components, not merely
repointed — but whether it survives is Leg 5's open fork, decided after Leg 4 under
"Sequencing". What is not in question is that the current vocabulary cannot stay: rewrite and
delete both end it, and doing neither leaves an authoring path writing columns the charge
path no longer reads.

**Two more step classes read that vocabulary from other live workflows**, and an earlier draft
filed both under the authoring workflow, which would have left them broken in place.
`PricingPlanSelection.pm:93,147` belongs to `workflows/tenant-signup.yml:18` — the path a
tenant takes to choose their platform plan, so it is on the signup money path, not the
authoring one. `GenerateEvents.pm:100` belongs to
`workflows/program-location-assignment.yml:21`. Neither is rewritten by Leg 5; both are
repointed in Leg 8, which is where their vocabulary actually goes away. This is not optional
polish: the milestone's own Pillar 5 test asserts that a plan authored through the CLI is
identical to one authored through the workflow, which cannot hold while the workflow writes
a vocabulary that no longer exists.

**`GenerateEvents` is a plan *writer*, and "repointed at `Entitlement`" is the wrong verb
for it.** `GenerateEvents.pm:96-102` calls `PricingPlan->create` with `session_id`,
`plan_type` and `amount_cents` when an admin sets a per-location price override — on a
tenant connection, so the row lands in `<tenant>.pricing_plans`. `Entitlement` is a read
path and has nothing to offer it. It is repointed at **`PriceOps::Model->publish_version`**,
which is why that method has to exist for ordinary application callers and not only for the
CLI. `PricingPlanSelection` is the other half of the same gap and needs a catalog read; see
"Which plans are offered, and to whom" below.

This has a consequence for Leg 4 that is easy to miss. If Leg 4 copies tenant rows up as a
one-shot snapshot and leaves this writer pointed at the tenant table, every program priced
between Leg 4 and Leg 8 has no registry-side row — and Leg 8's "refuse when nothing
resolves" then 500s the enrollment for exactly those programs. **Leg 4 repoints the writer
as part of the copy-up**: the migration is a write cutover, not a snapshot.

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
permanently this time), `name`, `slug`, and an `audience`. Drop `plan_type`:
`'early_bird'` / `'family'` / `'revenue_share'` / `'standard'` is precisely the string
vocabulary Pillar 4 forbids application code from branching on, and
`DAO/PricingPlan.pm:154,170` is the branch that goes.

**`plan_scope` is not implied by the provider, and an earlier draft dropped it saying it
was.** Registry offers two disjoint sets of plans and both have `provider_id` = registry:
the signup menu a tenant chooses from (`unified-pricing-infrastructure.sql:112,138`,
`plan_scope='tenant'`, read by `PricingPlanSelection.pm:93,147`) and the revenue-share
plans the platform applies to a tenant (`seed-free-platform-plan.sql:18`,
`plan_scope='platform'`, read by `RevenueShare.pm:58-64,114-120`). Same provider, two menus,
distinguished only by the column. Dropping it with nothing in its place loses the signup
page. It is renamed rather than deleted: `audience` — who the plan is *offered to* — which
is a different question from who provides it and deserves its own column.

**`pricing_plan_versions`** — the immutable envelope. `plan_id`, `version`, `requirements`,
`published_at`, `stripe_product_id`. Immutability enforced by a `BEFORE UPDATE`
trigger rejecting changes to a published version, not by convention — and reinforced
downstream, since the Stripe Price it publishes to is immutable by Stripe's own rules.

**The trigger has to name the one transition it permits, or it blocks publishing.**
`stripe_product_id` and `stripe_price_id` are filled in *at* publish, which is an UPDATE to a
row that is becoming published, and "publishing a version twice is idempotent" (Testing) is a
retry of that same UPDATE. So the rule is: a NULL Stripe id may become non-NULL; nothing else
on a published version may change, and a non-NULL Stripe id may not change. `published_at` is
the **last** write of the publish, not the first — see the publish ordering below.

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

**Components carry the same trigger as their version, and need two guards the version does
not.** "Immutable with their version" was stated and not enforced: without an UPDATE trigger,
`UPDATE pricing_components SET amount_cents = …` mutates a published price — which is the
`pricing_configuration.percentage` defect this design indicts, relocated one table over. So
components get the identical BEFORE UPDATE trigger, plus a BEFORE DELETE and a BEFORE INSERT
guard rejecting any change to the component set of a published version. A version is only
immutable if its children are.

**Publishing is N Stripe calls and one Postgres write, in that order.** A version with three
components is one Product call plus three Price calls, none of them transactional with the
database. If `published_at` were set first, a failure after component 1 would leave a
published version with NULL `stripe_price_id`s that the immutability trigger now refuses to
repair — permanently unschedulable and permanently unfixable. So: create the Stripe objects,
record every id, and set `published_at` last, gated on every component of the version having
a non-null `stripe_price_id`. `Entitlement` refuses to quote a version with any NULL
`stripe_price_id`, which is the runtime half of the same rule.

The payer-facing line item is generated from the component, not stored on it. A stored label
and a generator are two spellings of the same string that drift apart, which is #292.

Composition is the point. "2% plus $20/month" is two rows; "one-time setup fee, monthly
floor, percentage over that" is three; registry's own 2% is one row with `provider_id` =
registry. No count is special-cased and no combination of the existing kinds requires code.
A new *kind* does — see "Collection mechanisms".

**Which plans are offered, and to whom.** `Entitlement->quote` answers "what does this
consumer owe" and returns one Quote; it cannot answer "what may this consumer buy," which is
a list. Pillar 5 explicitly covers which plans display on a pricing page, so the read exists:
`PriceOps::Model->offered_versions($db, { provider, audience })` returns the latest published
version of each plan with that audience. `PricingPlanSelection` is repointed at this, not at
`Entitlement` — an earlier draft said `Entitlement` and had nothing for it to call.

**`pricing_schedules`** — replaces `pricing_relationships`, which already carries
provider/consumer/status and needs versioning and effective dating. `provider_id`,
`plan_version_id`, `effective_at`, `ends_at`, `status`. `tenants.platform_pricing_plan_id` is
superseded by it — but **not dropped when it is superseded**: it stays nullable and
dual-written from Leg 7 until Leg 9, for the reason given under "Legs 4 and 7 do not drop the
columns they replace."

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

**One plan in effect at a time, enforced by the database.** Pillar 2 says the plan in effect
at a moment determines the price, and "a moment" has to mean one row or the resolver has a
tie-break where it should have a fact. A GiST exclusion constraint on
`(provider_id, consumer_tenant_id, coalesce(consumer_user_id, uuid_nil()),
tstzrange(effective_at, ends_at))` where `status = 'active'` makes an overlapping schedule
unwritable. Without it, "the schedule in effect at `at`" is a convention that holds until the
first backdated correction.

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

**Quote columns on `payments`** — `plan_version_id`, `application_fee_cents`, the resolved
fee rate, and **`refund_application_fee`**, stamped beside the intent id. This closes four
review findings at once: the fee is never recorded, the rate can be retroactively rewritten,
the refund policy follows a tenant between plans, and "0% because Free" is indistinguishable
from "2%".

The refund flag is easy to leave off the list and the section falls apart without it.
"Refunds read the stamp" is the whole point of stamping, but the thing a refund needs is not
a rate — it is `refund_application_fee`, a policy boolean that
`RevenueShare.pm:87-106` reads live from `pricing_configuration` today. Stamp the rate and
not the boolean and the refund path still resolves from a mutable plan, which is the defect
being fixed.

Plus `stripe_account_id`, which the direct-charge move makes mandatory rather than nice to
have. A PaymentIntent id on a connected account is only retrievable with the `Stripe-Account`
header naming that account; without the column, `Job::ReconcilePayments` cannot look up its
own rows and a refund cannot find the charge it is reversing. It is the one piece of routing
information that is not derivable from the row itself once a tenant has more than one account
in its history.

**`stripe_account_id` therefore ships in Leg 3, not with the rest.** The argument for holding
the stamp until Leg 9 — that a stamp needs an immutable version behind it to record anything
true — does not apply to a routing identifier, which is true the moment the charge is
created. Leg 3 is the leg that must merge before the first tenant onboards, and leaving the
column until Leg 9 means every charge in a 20-to-30-day window is unreconcilable and
unrefundable by exactly the argument two paragraphs up. The column is additive and depends on
nothing.

**Stamping requires a mutator that `Payment` does not have.** `Payment::save`
(`Payment.pm:425-435`) writes a fixed six-column list, and every field is `:param :reader`
with no writer, so there is nowhere to put a quote before saving it. Leg 9 extends both: the
fields and the column list. This is the same defect as the `update`→`save` note under "Money
movement", and it is one fix.

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

Registry's multi-tenancy is structural cloning, not shared tables. `clone_schema` loops over
*every* `BASE TABLE` in the `registry` schema and issues
`CREATE TABLE <tenant>.<t> (LIKE registry.<t> INCLUDING ALL)`. It is indiscriminate: add a
table to `registry` and the next tenant onboarded gets an empty copy of it.

**The live definition is `sql/deploy/fix-clone-schema-identifier-quoting.sql`, not
`schema-based-multitennancy.sql`.** An earlier draft cited the latter throughout. It was
superseded on 2026-06-10 (`sql/sqitch.plan:56`), and since sqitch does not redeploy a
deployed change, an implementer who edits the file that draft named changes nothing in any
database. Leg 4 ships a **new sqitch change** carrying `CREATE OR REPLACE FUNCTION
registry.clone_schema(...)` forked from the current definition.

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

Two practical consequences of the two shapes. Leg 4's migration must **normalize before it
copies** — add the missing columns to old-shape tenant tables first, with the same
`CONTINUE WHEN NOT EXISTS` schema guard `sql/deploy/pricing-plans-amount-cents.sql:39-60`
already uses — rather than assuming a uniform source. And Leg 9's revert cannot honestly
restore what it drops: it would have to rebuild `<tenant>.pricing_plans` from registry rows
that have moved on, in a shape that differs per tenant. It recreates the current shape only
and says so in its ABOUTME, which is the house style — `sql/revert/pricing-plans-amount-cents.sql:9-14`
and `sql/revert/enhanced-pricing-model.sql:38-41` both document their own lossiness rather
than pretending.

`pricing_plans.session_id` survives this. It is not scope and not type — it is the link from
a plan to the product it prices, and it is what makes Resolution step 2 ("the product's own
plan version") resolvable at all. It stays on `pricing_plans`, nullable, and is how a
transactional enrollment quote finds its components when no schedule row governs.

**The exclusion is every loop that names a table, and it lands in Leg 4.** In
`fix-clone-schema-identifier-quoting.sql`, `clone_schema` copies sequences (`:318-356`),
tables (`:359-381`, with a nested column-default loop at `:369-377`), foreign keys
(`:384-395`), functions (`:399-407`), triggers (`:411-457`) and views (`:460-474`), and
`set_config('search_path', dest_schema, true)` means an unqualified reference inside any of
them resolves to the *destination* schema. Every table-shaped loop needs the same skip list
or the table arrives without its constraints instead of not arriving. The functions loop is
exempt — it copies routines, not tables. It ships in Leg 4 alongside the tables themselves,
not in Leg 7: a tenant onboarded between those two legs would otherwise be born with clones
nobody expects.

**The trigger loop is the one that fails loudly, and that is the good case.** It iterates
every trigger on every source-schema table and issues `CREATE TRIGGER … ON <dest>.<table>`.
Leg 4 puts a `BEFORE UPDATE` immutability trigger on `registry.pricing_plan_versions` — a
table the skip list excludes — so a skip list applied to the tables loop but not the triggers
loop makes the next `clone_schema` raise `relation "<tenant>.pricing_plan_versions" does not
exist` and **tenant onboarding hard-fails**. Loud is better than the alternative, but this is
the specific reason "all the loops" is not pedantry.

One consequence for the quote stamp: `payments` is a tenant-schema table, so
`payments.plan_version_id` **gets no foreign key** to `registry.pricing_plan_versions`.
`clone_schema`'s FK loop rebuilds constraints against the destination schema, so a
cross-schema FK would be rewritten to point at a `<tenant>.pricing_plan_versions` that must
not exist. It is a plain `uuid` column, and the tenancy invariant test below is what stands
in for the constraint.

### Collection mechanisms

Cadence × kind is four mechanisms. All four ship; one ships in its simple form only.

**This table is where the "no code for a new plan" promise stops, and the boundary should be
stated rather than discovered.** Composing existing kinds — any number of components, any
mix of cadences and currencies — genuinely needs no code, and that is the claim the
acceptance criterion tests. A new *kind* is a new row in this table, which is a new Stripe
call, which is code. `tiered` is out of scope for exactly that reason. The design delivers
Pillar 1 on the composition axis and not on the kind axis, and calling a new kind "an append,
which is what an append-only model is for" would be false: appends are cheap for versions,
not for mechanisms.

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

One property to state, because it looks like a bug from either direction: the percentage is
stamped on the Stripe Subscription at creation and **a later schedule change does not reach
subscriptions that already exist**. The disconnect handling below depends on this being true.
So a rate change applies to new subscriptions, and moving an existing provider's rate is a job
that rewrites `application_fee_percent` on their active subscriptions — not a side effect of
writing a schedule row. Until that job exists, a rate change is a forward-only change and the
CLI says so.

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

**Pillar 3 therefore ships as recording, not as billing.** Leg 10 creates `metering_events`
and starts writing it, including for zero-priced events, because the pillar's whole point is
holding volume *before* anyone decides to charge for it and that data cannot be backfilled.
"From day one" in an earlier draft was aspiration, not sequencing — day one is Leg 10, and
every event before that leg is lost, which is the actual argument for not sliding it later.
Forwarding those rows to Stripe as meter events is what waits, and it waits for a usage-based
component kind to consume them.

### Account configuration

Stripe deprecated the legacy account types while this design was being written, and Registry
has zero connected accounts — so this is the last moment the choice is free.

> "The information on this page applies only to platforms that already use legacy connected
> account types (Standard, Express, or Custom accounts). If you're setting up a new Connect
> platform, or your integration uses the Accounts v2 API, see the Interactive platform
> guide."

The spec's earlier text named **Standard** accounts throughout, following
`docs/operations/sacp-stripe-connect-onboarding.md:3,11`. Standard is exactly right on the
properties this design depends on — Supported charge types: *Direct only*; Fraud and dispute
liability: *Connected account for direct charges*; Dashboard access: *Full* — but it is the
deprecated spelling of them.

**Decision: the Accounts v2 API** (`/v2/core/accounts`), with
`defaults.responsibilities.losses_collector = stripe`,
`defaults.responsibilities.fees_collector = stripe`, and `dashboard = full`. That is
Standard's shape expressed in the current vocabulary:

| What it settles | Value | Consequence |
|---|---|---|
| Negative-balance liability | `losses_collector: stripe` | Stripe monitors risk and pursues negative balances. Registry, which is one person, does not become a risk operation. |
| Who pays Stripe's processing fees | `fees_collector: stripe` | Stripe bills the tenant directly; Registry's revenue share sits on top as the application fee. Registry never fronts processing costs and never has to bill them back. |
| Dashboard | `dashboard: full` | The tenant gets a real Stripe Dashboard and Stripe's support. Registry is not tier-1 support for Stripe questions. |
| KYC | derived: `requirements_collector: stripe` | Not settable in v2; it follows from the two above. Stripe collects and maintains verification, including when requirements change. |

**Which of these can be walked back is the opposite of what an earlier draft claimed.** That
draft marked `dashboard` immutable. It is not: `dashboard` is a documented parameter of
`/v2/core/accounts/update`, and Stripe says *"We send the `v2.core.account.updated` event only
for updates to top-level properties, such as `dashboard` or `display_name`."* The rows that
deserve the warning are the two above it — the responsibilities pair is `required` at creation,
and whether it can be changed afterwards is **not settled by the reference either way**. Leg 3a
answers that with a test-mode account before Leg 3 creates a live one, because
`losses_collector` is the single choice in this design with a company-shaped consequence.

An earlier draft recommended **v1 Accounts with controller properties** instead, on the
grounds that Accounts v2 "buys nothing this milestone needs." Both halves were wrong.
Controller properties are the migration path for platforms *already on v1*; Stripe's
guidance for a new platform is v2. And v2 buys this milestone the one thing its central
claim needs.

**A v2 `Account` holds multiple configurations, and Registry needs exactly two of them.**
The **Merchant** configuration is the tenant collecting from families; the **Customer**
configuration is the tenant paying Registry. Stripe is explicit that they compose: *"You can
collect application fees from an `Account` with the Merchant configuration. Assigning the
Customer configuration to it doesn't affect that ability."* Under v1 those are two objects
and a map, and Registry already maintains both — `Subscription.pm:59-64` creates a Stripe
`Customer` and writes `tenants.stripe_customer_id`, while `stripe_connect_account_id` holds
the `Account`. So "a provider sells to a consumer, applied recursively" is not only
expressible in Stripe's object model, it is what v2's `Account` *is*, and Registry is
currently paying for the version that isn't.

The mechanism has a name the spec had not written down, and code has to use it: *"Any API
request with a `customer` parameter that accepts a `Customer` ID also has a
`customer_account` parameter that accepts an `Account` ID."* Every Registry→tenant
subscription and invoice call swaps `customer` for `customer_account`. The reason this is
not optional under v1 is the sentence after it: *"If you use the Accounts v1 API, you can't
pass an `Account` ID to an endpoint that expects a `Customer` ID."*

**The collapse moves out of Leg 3 and into Leg 9**, with the column drop it was always paired
with. Leg 3 is the one leg with a deadline — it must merge before the first tenant onboards —
and the collapse is the one part of it that has no deadline: Stripe supports adding a
configuration to an existing account afterwards, with *"Centralized identity data: When you
add a configuration to an existing `Account` to enable additional functionality, you don't
have to re-collect requirements that they already provided."* Nothing is lost by waiting and
Leg 3 gets smaller, which is worth more on the leg that gates taking money.

**The costs are four, not two, and they are the reason Leg 3 is the largest leg here.**

*Transport.* `Service::Stripe::_request_async:26` hardcodes `https://api.stripe.com/v1/$endpoint`
and form-encodes POST bodies at `:43`; v2 is a different path and takes JSON, so that method
gets a second branch. Only account creation and management move — PaymentIntents,
Subscriptions and Invoices are v1 objects and stay there.

*API version.* `Service::Stripe.pm:15` pins `Stripe-Version` to `2024-12-18.acacia`, which
predates Accounts v2 entirely — every v2 example in Stripe's current docs sends a
`2026-07-29` version. The pin is not incidental: `t/stripe-live/service-version.t` exists
solely to catch it drifting, and `DAO::Subscription.pm:71-103` is a *third* Stripe client
that sends no version header at all. Bumping a pinned version is a change to every v1 call
Registry makes, across a year and a half of Stripe releases, and it is not something to
discover halfway through Leg 3. **It ships as its own leg, before Leg 3** — see Leg 3a.

*OAuth is given up, and this is the one that surprised the fourth reviewer.* Stripe lists
using *"OAuth to authenticate connected accounts"* among the cases where **"You must use
Accounts v1"**. Choosing v2 therefore ends OAuth as an onboarding mechanism, and with it
`/v1/oauth/deauthorize` and the `account.application.deauthorized` event. An earlier draft
said a v2 account "uses the rejection API instead"; that was invented. See "disconnect" under
"Money movement" for what actually replaces it.

*The `t/stripe-live/` fixture may have no automatable replacement, and this is a risk to the
gate rather than a cost.* `t/lib/Test/Registry/StripeConnect.pm:79-113` gets a chargeable
account by creating `type: custom` and submitting KYC itself with Stripe's magic values —
which works only because a Custom account makes the *platform* the requirements collector.
Under `dashboard: full` the collector is Stripe, and there is no documented way for a
platform to satisfy verification on the account's behalf. If that has no equivalent, the
milestone's acceptance test cannot run unattended. **Leg 3a spikes this in test mode and
reports before Leg 3 commits to the configuration** — it is cheaper to learn now than to
finish Leg 3 and find the gate unrunnable.

What this does *not* cost is production onboarding code, because there isn't any:
`docs/operations/sacp-stripe-connect-onboarding.md:11-20` onboards a tenant by hand in the
Stripe Dashboard, and no module in `lib/` creates a connected account. The only code that
does is the test fixture above.

What this decision does *not* change: direct charges, `application_fee_amount`,
`application_fee_percent`, the tenant owning the dispute, and the embedded dispute
components. Stripe states embedded components work regardless of dashboard type, so Leg 12
is unaffected. Had `dashboard: none` been chosen instead, embedded onboarding, account
management and the notification banner would have become *mandatory* and moved into Leg 3 —
which is the main reason not to choose it.

### Resolution

```
Registry::PriceOps::Entitlement->quote($db, { provider, consumer, product, at }) -> Quote
```

1. Schedule row for (provider, consumer) in effect at `at` → its plan version governs. The
   exclusion constraint guarantees there is at most one.
2. Otherwise the product's own plan version — the transactional case. **The version is the
   latest published at `at`, and where a product has more than one plan the lowest total
   wins.** Both rules have to be written down: a session with two plans is the normal seeded
   state (`enhanced-pricing-model.sql:113-124` inserts a Standard plan beside every
   early-bird one) and `get_pricing_plans` (`PricingPlan.pm:126-133`) has no `ORDER BY`.
   Leaving step 2 to say only "the product's plan" reintroduces the unordered
   `$pricing_plans->[0]` this design deletes, one layer up and harder to see. Lowest-total is
   also what the existing code means to do (`PricingPlan.pm:214-224` takes a `min`).
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

**The same line has a second bypass, and the Quote does not touch it.** The condition is
`($info->{total} // 0) == 0 || !$ENV{STRIPE_SECRET_KEY}` — so an unset or misspelled key on a
production worker routes *every* paid enrollment to `create_demo_enrollments`, silently, with
no payment row. That clause goes with the rest of the line in Leg 8: the quote already
distinguishes owing money from not, and whether Stripe is configured is not a pricing
question. While the zero-price path survives, it also needs the conflict clause the paid path
has — `Enrollment::create_for_payment` (`Enrollment.pm:94-96`) uses
`ON CONFLICT … DO NOTHING` and `enroll_children` (`:103-121`) does not, so a double-submitted
free enrollment duplicates rows and confirmation emails.

**"Refuse when nothing resolves" needs every tenant to have something that resolves.** Today
a tenant with a NULL `platform_pricing_plan_id` falls back to the seeded Free plan
(`RevenueShare.pm:43-45` → `platform_default_fraction`), and signup can complete without
choosing a plan at all — `PricingPlanSelection.pm:24-27` returns `{}` and advances when none
are configured, and `TenantPayment.pm:429` writes the pointer only if one was selected. Turn
that fallback into an error without filling the gap and those tenants stop being able to
charge anyone: `revenue_share_fraction_for_tenant` dies on every enrollment in their schema.
So Leg 7's migration writes a schedule row for **every** tenant, Free v1 where the pointer is
NULL, and Leg 8 makes signup write one unconditionally. Refusing is only safe once absence
has been made impossible rather than merely undesirable.

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

  **`save` is not a drop-in for `update` and a literal swap corrupts the row.** `save`
  (`Payment.pm:425-435`) writes the object's in-memory fields, and every field is
  `:param :reader` (`:12-23`) with no writer — so `Webhooks.pm:136`, which currently passes
  `{ status => 'completed', … }` from outside the class, has no way to set the status first.
  Swap it literally and the webhook writes back the loaded `'pending'` and a NULL
  `completed_at`: it *un-completes a paid enrollment*, loudly. The fix is a mutating method on
  `Payment` — `mark_completed($db, $intent_id)` — that sets the fields and calls `save`, with
  the webhook calling that. Leg 0 owns it, and Leg 9 extends the same field list and column
  list for the quote stamp.
- **Reconciliation.** `Registry::Job::ReconcilePayments`, registered like the existing
  jobs (`Registry.pm:72-75`). It retrieves the intent and writes down what Stripe says —
  it never infers. Stripe being the source of truth is what makes this job trivially
  correct instead of a second opinion. Step 1 closes the hole; this finds what the hole
  already ate.

  **Scoping it to `pending` misses the rows that actually lose money.** Two paths write
  `failed` against a charge that may have succeeded at Stripe: `_record_retrieval_failure`
  (`Payment.pm:242-247`) on a transport error, and `_record_intent_failure` (`:218-226`),
  which leaves `stripe_payment_intent_id` NULL as well. A network blip on the parent's return
  from a successful 3DS produces exactly the first. So the scan covers
  `status IN ('pending','processing','failed')` with an intent id, and `failed` rows with no
  intent id are matched against Stripe by their idempotency token. A job that only reads
  `pending` backstops the case that was already going to heal itself.
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
  `Service::Stripe::_request_async` (`:25-32`) as an optional per-call account, because every
  method already routes through it and adding it anywhere else means adding it repeatedly.

  **Optional must not mean "falls back to the platform".** `_connect_params` returns `()`
  when the tenant has no account (`Payment.pm:84-86`); with a per-call account that is merely
  optional, the same shape lands the charge on the *platform* account with Registry as
  merchant of record — the precise inverse of this leg's purpose. Today the only thing
  preventing it is the `stripe_connect_ready` gate in the workflow step
  (`WorkflowSteps/Payment.pm:131`), which is one caller away from the money. `Payment` refuses
  a charge whose `metadata.tenant_slug` is a real tenant and whose account is missing, rather
  than proceeding without the header.
- **Idempotency keys stop at PaymentIntents, and refunds are where that hurts.**
  `_request_async` has taken an idempotency key since `:25` and sets the header at `:32`, but
  only `create_payment_intent_async` (`:72-76`) passes one. `create_refund_async` (`:173-175`)
  and `create_subscription_async` (`:147-149`) do not. A socket timeout on `POST /v1/refunds`
  is indistinguishable from a rejection — `Payment.pm:456-466` turns any failure into a die —
  and under direct charges a retried refund comes out of the *tenant's* balance twice. The
  same shape on subscriptions leaves a family with two live memberships and Registry taking
  two application fees. Both get a key, derived from the payment id and amount, exactly as
  PaymentIntents already do. Leg 3 for refunds, Leg 8 for subscriptions.
- **`application_fee_amount` is omitted, never zero — and nothing currently owns that.**
  It is stated under "Collection mechanisms" as a Stripe restriction and then contradicted by
  shipped behaviour: `Payment.pm:94-96` sends it unconditionally and
  `t/dao/payment-intent-destination-charge.t:189-190` asserts it is `0` for the Free plan. The
  absence-versus-zero discipline this whole design rests on cannot have an exception on the
  charge itself. Leg 8 omits the parameter when the quote resolves to no fee and re-cuts that
  assertion.
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
- **Under direct charges the tenant can refund without us, and today we would not notice.**
  Whatever "Account configuration" settles on gives the tenant a Dashboard on the account the
  charge now lives on. A refund issued there emits `charge.refunded`, which Registry has no
  handler for: `Webhooks.pm:61-81` matches `payment_intent.succeeded`, `account.updated` and
  the installment branch, and everything else falls through to
  `Subscription::process_webhook_event`, which marks unrecognised types `processed`
  (`Subscription.pm:244-247`) and moves on. The payment row stays `completed`, the enrollment
  stays active, and the application fee is never reversed — Registry keeping a fee on a
  refunded charge, which is the mirror of the warning two bullets up. `charge.refunded` and
  `charge.dispute.closed` handlers that project Stripe's `amount_refunded` and
  `application_fee_amount` back onto the row ship with Leg 3, because that is the leg that
  hands the tenant the button.
- **The signature parser keeps one `v1`, and Leg 3 makes that a rotation hazard.**
  `Webhooks.pm:171-178` assigns `$sigs{v1} = $value` inside the loop, so a header carrying
  several `v1=` signatures — which is what Stripe sends during a secret rollover — is checked
  against the last one only. `Service::Stripe.pm:209-215` has the same shape. Leg 3 adds a
  second endpoint and secret, and rotation is the standard response to a leak, so the failure
  mode is a direct charge succeeding at Stripe while Registry never hears about it: the exact
  defect Leg 0 exists to fix, reintroduced through configuration. Collect the `v1` values and
  accept if any verifies, against any configured secret.
- **`account.updated` needs an ordering guard before Leg 3 leans on it.**
  `Webhooks.pm:152-159` blind-writes `stripe_charges_enabled` with no comparison against the
  event's timestamp, and that column is the paid-enrollment gate
  (`Tenant::stripe_connect_ready` → `WorkflowSteps/Payment.pm:131`). Stripe does not guarantee
  ordering and retries make reordering routine, so a stale `charges_enabled: true` arriving
  after a genuine disable re-opens the gate on an account Stripe has stopped — the charge then
  fails with the parent's card on screen. Store the event timestamp and refuse to apply an
  older one.
- **A single Stripe client.** `Registry::Client::Stripe` (198 lines) is deleted. Its only two
  callers — `PriceOps/ScheduledPayment.pm:18` and `PriceOps/PaymentSchedule.pm:19` — are
  already deleted by Leg 1, which is the whole argument. An earlier draft justified it by
  calling twenty-one of its twenty-six methods thin pass-throughs; that is not quite true and
  the truth is worse for the class, not better — **seven of the seventeen delegations call
  `Service::Stripe` methods that do not exist**, so they would die if anything reached them.
  It is dead code that also does not work. `Service::Stripe` becomes the sole client and is
  not renamed: roughly ten test files monkey-patch it by fully-qualified name, and that is
  churn for a noun.
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

  **Under Accounts v2 there is no revoke endpoint and no deauthorized event, and the design
  is better for it.** Both are OAuth mechanisms, and OAuth is on Stripe's list of cases where
  *"You must use Accounts v1"*. The other candidate does not work either: `/v2/core/accounts/
  {id}/close` returns `stripe_loss_liable_cannot_be_deleted` — *"Account with Stripe-owned
  loss liability and dashboard cannot be deleted"* — which is precisely the configuration
  chosen above. So Registry cannot revoke, close, or delete a tenant's account.

  That is the correct outcome rather than a missing feature. With `losses_collector: stripe`
  and `dashboard: full`, the account is the tenant's property and their relationship with
  Stripe; Registry is a platform they granted access to, not the owner of their merchant
  identity. Disconnect is therefore entirely a Registry-side operation, and it is the same
  list of work minus the last step:

  **Registry-initiated** is a "disconnect from Registry" action that ends the tenant's
  schedule rows, clears `application_fee_percent` from every subscription Registry created on
  that account, stops the charge path from resolving that tenant, and clears
  `stripe_connect_account_id`. The ordering argument in the earlier draft — clear the fees
  *before* revoking — evaporates along with the revoke call, but clearing the fees does not:
  a subscription left with `application_fee_percent` set keeps paying Registry after the
  relationship ends, and nothing external stops it.

  **Account-initiated is an open question Leg 3a must answer, not a handler we can specify.**
  With OAuth gone there is no `account.application.deauthorized` to hook, and whether a
  full-dashboard v2 account offers the tenant any "remove this platform" affordance at all is
  not stated in the reference. Two possibilities, and Leg 3a's spike distinguishes them: if
  there is no such affordance, the account-initiated case does not exist and only the
  Registry-initiated path is needed; if there is one, the signal is capability loss on
  `account.updated` rather than a dedicated event, and detection becomes reconciliation —
  which is what `Job::ReconcilePayments` in Leg 12 is already for. **Do not write a handler
  for an event that may not fire.** What survives either way is the obligation: tell the
  tenant that our fee is still attached to their subscriptions and that they can clear it
  themselves (*"After disconnect, a connected account can clear the `application_fee_percent`
  parameter from existing Subscriptions through the API"*). A platform that keeps quiet here
  is one that keeps collecting from someone who left.

  Also worth recording, because it reads as a bug when discovered live:
  *"Subscriptions aren't automatically canceled when you disconnect from the platform."*
  Families stay subscribed to a tenant who left Registry. That is correct — the tenant is the
  merchant and the service is theirs — but it means our enrollment records go stale silently,
  and the handler should mark them rather than let a dashboard imply we still know.
- **The charge path has no database-level concurrency control, and its guards are all in
  Perl.** `Payment.pm` contains zero `$db->begin` and zero `FOR UPDATE` — a count, not an
  impression. The application-level protections added in #283 are real and this is not a
  claim that double-submit is unguarded: `WorkflowSteps/Payment.pm:26-31,180-181,254-261`
  detects a stale intent, cancels the superseded one, and treats `already_completed` as
  success. But every one of those is a read followed by a decision followed by a write, on a
  row nothing is holding. Two requests interleaving between the read and the write get past
  all of it. Leg 0 is already establishing "one transaction, one connection" for the webhook
  half; the charge half needs the same discipline — `SELECT … FOR UPDATE` on the payment row
  before deciding what to do with its intent. Capacity has the same shape and a worse
  consequence now: it is checked once at quote time and never re-checked at capture, and
  under direct charges the refund for an oversold seat comes out of the *tenant's* balance
  rather than ours.
- **Nothing on the money path logs anything.** `grep -c 'log->'` returns 0 for both
  `DAO/Payment.pm` and `Service/Stripe.pm`. No request is logged, no response, and Stripe's
  `request_id` — the identifier their support asks for first — is captured nowhere. Two
  `->catch(sub {})` blocks swallow errors silently. This is tolerable while nobody is paying;
  it is not tolerable the first time a parent's money goes somewhere unexpected and the only
  record is what Stripe's dashboard chooses to show. Leg 0 adds structured logging to both,
  keyed on `request_id`, because Leg 0 is where the money path stops being best-effort.
- **The payment row's currency is always `'USD'`, and no caller has ever chosen it.**
  `Payment.pm:15` declares `field $currency :param :reader = 'USD'` and `:195` writes it, so
  the column is populated — this is not a dropped value. But the only non-installment caller,
  `WorkflowSteps/Payment.pm:193`, passes no `currency`, so the default is the value every
  time. That is invisible today and wrong the moment a plan bills in two currencies, which
  this design explicitly supports. The quote knows the currency; Leg 9 is where it reaches
  the row, alongside the other quote columns.
- Plus #284, #289, #293, and the tenant-subscription lifecycle fix. Registry→tenant subscriptions
  are platform-account objects and still need `$tenant_id` passed through to
  `create_subscription_with_config` (`TenantPayment.pm:340-344` vs `Subscription.pm:118`)
  so the five handlers that bail on `return unless $tenant_id` can run.

  **Those handlers must not be reached by tenant→family events**, and the obvious fix would
  reach them. `Subscription.pm:263,280,296,314,327` each resolve
  `$subscription->{metadata}{tenant_id}` and then call `update_billing_status`
  (`:188-204`), which does `UPDATE registry.tenants SET billing_status = ?`. Under direct
  charges a family's membership renewal produces the same `customer.subscription.updated` and
  `invoice.payment_*` event types — so feeding these handlers a tenant id derived from the
  event's `account` field, as an earlier draft proposed, would let a parent's failed card mark
  the *tenant* `past_due` and a cancelled membership mark them `cancelled`. The `account`
  field identifies the **provider**, never the consumer. The dispatch rule is therefore the
  envelope, not the metadata: an event carrying an `account` is a tenant→family event and
  routes to the enrollment path; an event with no `account` is a platform-account event and is
  the only kind allowed to touch `billing_status`.

  **That guard belongs in Leg 8, not Leg 12.** `PriceOps::Schedule` starts creating family
  subscriptions on connected accounts in Leg 8; the events begin arriving the same day. Held
  until Leg 12 there is a window in which a parent's declined card marks their *tenant*
  `past_due`. It is a guard clause, not a feature — the dispute surface and
  `ReconcilePayments` can stay in 12.

  An earlier draft added that `update_billing_status` "has no caller in `lib/` at all," which
  is false and contradicted the same paragraph: it is called by all five handlers
  (`Subscription.pm:277,293,311,324,337`). The write path is live. What it lacks is a
  *reader* — `billing_status` is written and never consulted — which is a smaller problem and
  a different one.

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

Installments are cut. ~3,000 lines across `lib/` and `t/` (twelve files dedicated to
`payment_schedules`/`scheduled_payments`, 3,016 lines), the `Webhooks.pm:69-71,204-289`
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

`PriceOps/PricingPlan.pm` goes in Leg 1. It is not dead — it is a discount calculator that
branches on `plan_type` at `:99,110,129,171` for `early_bird` and `family`, a vocabulary
this design replaces with components. Deleting it early is safe only because the discount
form it serves is deleted in the same leg; if that ordering slips, they slip together.

`PriceOps/UnifiedPricingEngine.pm` and `PriceOps/PricingRelationships.pm` are deleted **in
Leg 7, not before** — they are the only code in `lib/` that can write a
`pricing_relationships` row, so they must be replaced rather than removed ahead of the
replacement. `DAO::PricingRelationship`, `DAO::PricingRelationshipEvent` and the
`registry.pricing_relationship_events` table die with them. Close #76.

`registry.billing_periods` and `DAO::BillingPeriod` are dropped in Leg 7 rather than
alongside the rest of the deletions, and the reason is a foreign key rather than a
preference: `billing_periods.pricing_relationship_id` references
`registry.pricing_relationships(id)` (`sql/test-schema.sql:4431`). Dropping
`pricing_relationships` without dropping `billing_periods` first fails, so the two go in
one migration.

## Sequencing

Legs are renumbered from the previous draft: the old 2a/2b lettering is gone, the old Leg 2
is split in two, and the old Legs 6 and 7 collapse into one recording-only leg.

**Estimates are in sessions, not days.** A session is one context window of focused work,
250k-500k tokens, from a cold start to a commit. It is the honest unit for this project
because it is the unit the work actually comes in: a session ends when the context is spent,
not when a clock runs out, and what spends it is files read, edits made, and test output
consumed. Day estimates for agent-assisted work have been wrong by large factors here in
both directions, and they smuggle in an assumption about how many hours anyone sits down for.
Sessions do not.

Read the ratios rather than the total. What the table claims with confidence is that Leg 3 is
five times Leg 10 and that Legs 3, 4 and 8 are where the milestone lives; the absolute count
is the weaker claim. Ranges are wide where a leg's cost depends on how much of the E2E suite
has to be re-cut rather than extended.

| Leg | Content | Depends on | Sessions |
|---|---|---|---|
| 1 | Safe deletions: installments, `Client::Stripe`, `PriceOps/PricingPlan.pm`, misfiled tests, #296, discount form | — | 2-3 |
| 0 | The money path becomes atomic and observable: webhook atomicity in one transaction on one connection (**#247** is a prerequisite, not a follow-up); `update` → `save` via a mutating `mark_completed`; **`SELECT … FOR UPDATE` on the payment row so the #283 stale-intent guards hold under concurrency**; **capacity re-checked at capture**; **structured logging in `DAO/Payment.pm` and `Service/Stripe.pm` keyed on Stripe's `request_id`**, and the two silent `->catch(sub {})` blocks closed | 1 | 3-4 |
| 2 | **#294**: collapse `registry-platform` into `registry`; retire the all-zeros UUID as a provider identity, in `lib/` **and 21 test files including `t/lib/Test/Registry/Helpers.pm`** | 1 | 2-3 |
| 3a | **Bump `Stripe-Version` off `2024-12-18.acacia` to a v2-aware version**, in `Service::Stripe.pm:15`, `t/stripe-live/service-version.t` and `DAO::Subscription.pm:71-103` (which sends none); **spike a chargeable full-dashboard v2 account in test mode** and report whether `t/lib/Test/Registry/StripeConnect.pm`'s KYC path has an equivalent; confirm whether `defaults.responsibilities` is updatable | 1 | 2-3 |
| 3 | Charge model: **Accounts v2 (`losses`/`fees` = `stripe`, `dashboard` = `full`)**; `Service::Stripe` gains a JSON `/v2/` branch; tenant→family becomes direct charges; `Stripe-Account` in `Service::Stripe` (refusing, not falling back); refunds lose `reverse_transfer` and gain an idempotency key; `charge.refunded` and dispute-*recording* handlers; multi-`v1` signature and multi-secret; `account.updated` ordering guard; **`payments.stripe_account_id`**; Payment Element `stripeAccount`; **two webhook endpoints — Connect for v1 events, platform for `v2.core.account.*` thin events — and their secrets**; **a tenant `SELECT` by `stripe_connect_account_id`**; Registry-initiated disconnect | 0, 1, 3a | 4-6 |
| 4 | `pricing_plan_versions` / `pricing_components` + immutability triggers; `pricing_plans` gains `provider_id` and `audience`, keeps `session_id`; **new `clone_schema` sqitch change with the skip list in every table-shaped loop**; normalize the two tenant table shapes, then migrate registry **and every tenant schema's** plans to v1; **repoint `PricingPlan->create` at the registry table**; `plan_scope`/`plan_type`/`pricing_configuration` kept nullable and dual-written by `PriceOps::Model->publish_version` | 2 | 4-6 |
| 5 | Rewrite the `pricing-plan-creation` workflow and its templates onto the version/component vocabulary — **or delete it; decided after Leg 4, see below** | 4 | 0-4 |
| 6 | Publish projection: version → Stripe Product, component → Stripe Price **on the provider's account**; ids recorded; `published_at` written last; **backfill-publish every v1 migrated in Leg 4**; `Subscription.pm` stops building inline `price_data` | 3, 4 | 2-3 |
| 7 | `pricing_schedules` + the overlap exclusion constraint; migrate `pricing_relationships` + `platform_pricing_plan_id` (**column kept nullable and dual-written**), writing a schedule row for **every** tenant; drop `billing_periods` and `DAO::BillingPeriod`; delete the dead modules | 4 | 2-3 |
| 8 | `Entitlement` + `Quote` + `Model->offered_versions`; rewire the charge; **`Schedule` creates direct-charge subscriptions with `application_fee_percent`** and an idempotency key; **subscription envelope dispatch**; omit-never-zero `application_fee_amount`; repoint `PricingPlanSelection` and `GenerateEvents`; delete `calculate_enrollment_total` and the `!$ENV{STRIPE_SECRET_KEY}` bypass; refuse-not-zero; `RevenueShare` becomes a wrapper | 6, 7 | 4-6 |
| 9 | Quote columns on `payments` incl. `refund_application_fee` **and the quote's currency, which no caller has ever passed**; `Payment` fields and `save` column list extended; fee recorded; `DAO/AdminDashboard.pm:36` corrected; **add the Customer configuration to each tenant's `Account` and swap `customer` for `customer_account`**; **drop the deprecated columns, `tenants.stripe_customer_id`, and the tenant-schema `pricing_plans`**; check `sql/verify/stripe-subscription-integration.sql:9` | 8 | 3-4 |
| 10 | **Create `metering_events`**; `Metering`: record every monetizable event including zero-priced ones | 7 | 1 |
| 11 | Pillar 5: `./registry pricing` CLI + CHECK constraints; retire hand-typed SQL seeds | 4, 5 | 1-2 |
| 12 | Dispute resolution *surface*: admin page, embedded components, AccountSession; `Job::ReconcilePayments`; **widen the CSP at `Registry.pm:524,527`, which today allows only `js.stripe.com` and will block Connect's embedded components**. The `charge.dispute.*` handlers themselves are Leg 3 — Leg 12 is what a human sees | 0, 3, 9 | 2-3 |

**32 to 51 sessions** — 8 to 26M tokens, a spread wide enough that the token figure is
context rather than a budget. The ceiling moved up from 49 because the money-path hardening
folded into Legs 0, 9 and 12 is real work; the floor moved *down* from 33 for a reason that is
not a saving. Leg 5's range starts at zero because its content is a decision Leg 4 makes, not
a quantity of work anyone has agreed to yet, and a floor that assumes the cheapest branch of
an undecided fork is the least trustworthy number in the table.

Legs 3a, 3, 4 and 8 are 14 to 21 of that, about 40% in four legs, and the concentration is the
useful signal: they are the charge model, the model tables and the resolver, and each is
large because it touches code rather than because it adds a table. Leg 3 accumulated five
hardening items that stop being optional once the tenant holds the account; Leg 4 needs a new
`clone_schema` change, a shape normalization and a write cutover rather than one migration;
Leg 8 is where every read path moves at once.

**Leg 3a is a spike and a version bump, and it is deliberately in front of the deadline
leg.** Both halves are cheap to do early and expensive to discover late: a pinned API version
touches every Stripe call Registry makes, and the account-fixture question decides whether
the milestone's acceptance test can run at all. If the spike comes back saying a
full-dashboard v2 account cannot be provisioned unattended, that is an argument to revisit
`dashboard: full` — which is exactly the kind of finding that must arrive before Leg 3, not
after it.

**Leg 5's content is decided after Leg 4, and that deferral is the point.** The fork is
between rewriting `workflows/pricing-plan-creation.yaml` — 862 lines of step classes and
1,412 lines of templates — onto the version/component vocabulary, and deleting the surface
outright. Deciding now would mean deciding from a line count. Leg 4 is what makes the real
question legible: once `pricing_plan_versions` and `pricing_components` exist and
`PricingPlan->create` points at the registry table, the gap between what the workflow's five
steps collect and what a version needs is something to read rather than estimate. That gap is
the criterion. If the steps map onto components with a rename and a reshape, rewrite. If the
version model wants a different set of questions than the workflow asks, delete it and let
Leg 11's CLI be the only authoring path until a tenant asks for one back.

Two consequences, and they point opposite ways. The dual-write argument below survives either
branch, because it needs the current writers *gone* and delete removes them as surely as
rewrite does. Pillar 5's acceptance test does not survive: invariant 5 compares a CLI-authored
plan against a workflow-authored one, so deleting the workflow deletes the second author and
the invariant has to be rewritten as a CLI-only assertion. That rewrite is part of the cost of
the delete branch, not a discount on it.

The cheap legs at the bottom are cheap because Legs 4 and 7 will already have built what they
need — Pillar 3 is one of the five pillars and `Metering` costs a single session. That is the
sequencing paying off, not those legs being unimportant.

Two things reliably cost more sessions than their diffs suggest, and the estimates above
include them. A schema leg pays for a `make test-schema` regeneration and whatever the full
suite then turns up, and the suite is ~76 minutes with output that has to be read. And Legs
2 and 5 are wide-and-shallow — 21 test files, 1,412 lines of templates — which is the shape
that spends a context window fastest, because it is all reading and no thinking.

That number is the argument for shipping legs rather than a milestone: 1, 0, 2 and 3 are
independently valuable. Leg 3 is the one with a deadline attached — it must merge before the
first tenant onboards — and it does not depend on any of the pricing model work.

**Leg 1 goes first, and Leg 0 depends on it.** An earlier draft had both depending on nothing
and put 0 first. Leg 0's rule is one `begin` at the top of `stripe()` and no other transaction
below it, but `Webhooks.pm:69-71` still routes to `_process_installment_payment_event`, which
reaches `PriceOps/ScheduledPayment.pm:80` and `DAO/PaymentSchedule.pm:59-61` — both of which
open their own `$db->begin`. A nested transaction committing early reverts the `search_path`
mid-handler and releases the atomicity Leg 0 exists to establish. Leg 1 deletes that code, so
swapping the order costs nothing and Leg 0 cannot ship correctly without it.

**Legs 4 and 7 do not drop the columns they replace.** `RevenueShare.pm:58-64,114-120`
selects the platform plan by `plan_scope='platform'` and `:35,95` joins on
`tenants.platform_pricing_plan_id`. Both are live on the charge path, and their replacement
does not exist until Leg 8. Dropping either when its successor table lands would break
collection for four legs. So both stay nullable and dual-written from the leg that
supersedes them until Leg 9 removes them — one migration later than feels tidy, which is
the correct trade when the alternative is an unpriced enrollment.

**Dual-writing needs a named owner, and it is `PriceOps::Model->publish_version`.** "Stays
dual-written" is not a property a column has; it is work some function does, and if no
function is named the window silently becomes a single-write window. The owner has to be
`publish_version` because Leg 5 rewrites every current writer off the old vocabulary:
`PricingPlan.pm:62` defaults `plan_scope` to `'customer'`, `PricingPlanBasics.pm:49` and
`ReviewActivatePlan.pm:102,171` carry it through the authoring workflow,
`UnifiedPricingEngine.pm:97,130` sets it on two paths, and `TenantPayment.pm:429` writes
`platform_pricing_plan_id` at tenant signup. Once those are gone, nothing writes the
columns `RevenueShare.pm:61,117` still selects on — and it does not fall back, it dies with
*"This is a deployment bug"* (`:67-68`, `:123-124`). So from Leg 5 through Leg 9, `publish_version`
writes the legacy `pricing_plans` row alongside the version, mapping `audience` back to
`plan_scope`, and the tenant-signup step writes both a schedule row and
`platform_pricing_plan_id`. Leg 9 deletes the second write and the columns in the same
migration.

**Every one of these legs also assumes its migration ran, and production does not
guarantee that.** `docker-entrypoint.sh:20-24` runs `sqitch deploy`, and on failure prints
`"Warning: Database schema deployment failed"` and starts the app anyway — new code
against an old schema, which for a pricing leg means the resolver querying a table that
does not exist on a live checkout. The worker is worse: `render.yaml:75` defines it with no
migration step at all, so it boots against whatever schema the web service happened to
leave behind, and the worker is what runs the payment jobs. This is not caused by this
milestone, but this milestone is what makes it expensive — fourteen legs, seven migrations,
each one a chance to serve new pricing code against old tables. Making a failed deploy fail
the container is a one-line change and a prerequisite for shipping any leg to production.

**And when a leg goes wrong there is currently no way back.** Three things are missing and
each is cheap next to what it protects:

*A revert that works.* Seven of the 64 scripts in `sql/revert/` do nothing — comments and a
`BEGIN`/`COMMIT` wrapper around no statements — and two of those seven,
`auth-notification-types.sql` and `seed-registry-storefront.sql`, do not even have the
wrapper. `sqitch revert` against any of them succeeds and changes nothing, which is worse
than failing.
**Every migration in this milestone ships with a revert that is tested by reverting it**, and
that test is part of the leg, not a follow-up. This is already in Testing as "a revert test
per migration"; it is repeated here because the sequencing is where it will be skipped.

*A backup taken before the leg, not after the problem.* `README.md:130` still has the backup
item unchecked. A pricing migration that mangles rows is not recoverable from a revert script
alone, because the revert restores the schema and not the data.

*A named half-deployed state per leg.* Legs 4, 6, 7 and 9 cannot safely be left half-done —
Leg 6's publish backfill in particular is non-transactional with no retry, so a partial run
leaves some versions with Stripe ids and some without, and the ones without are unsellable.
Every leg states what "stopped halfway" looks like and whether it is safe to sit there
overnight. Where the answer is no, the work is either one transaction or idempotent enough to
re-run from the start; Leg 6's backfill becomes the latter.

The three Render services — web, worker and cron at `render.yaml:39,75,96` — all carry
`autoDeploy: true` (`:69,94,110`) and only the web service runs migrations, so a merge deploys
all three independently against a schema one of them just changed. There is no staging environment and no feature flag anywhere in this
design. That is survivable for legs that only add tables; it is the reason Legs 8 and 9 —
which move every read path and then drop the columns behind it — should be the two legs that
get a manual deploy rather than an automatic one.

The same rule covers the tenant-schema `pricing_plans` tables, and there the stakes are
higher because those rows are a tenant's actual program prices rather than a nullable
pointer. Leg 4 copies them up into `registry.pricing_plans` with `provider_id` set and
leaves the originals in place, still read by `PricingPlan->get_pricing_plans` through the
tenant `search_path`. Only Leg 9, after `Entitlement` has been the sole read path for a leg,
drops them. **The `clone_schema` exclusion moves to Leg 4** for the same reason in the other
direction: it must land with the tables, or a tenant onboarded in the gap between Leg 4 and
Leg 7 is created with clones of the new tables and immediately violates the invariant.

Leg 0 ships second, immediately after Leg 1, and nothing waits on it: it can lose a paid
enrollment today, and Leg 1 is only ahead of it because of the nested-transaction problem
above. An earlier draft said "Leg 0 ships alone and first: depends on nothing else here",
which survived the renumbering it contradicted.

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

**"Nearly free" is a claim about `lib/`, and the tests are where it stops being true.**
Twenty-one test files hold the literal all-zeros UUID, spread well beyond the pricing
tests — `t/security/workflow-validation.t`, `t/robustness/db-constraints.t`,
`t/controller/teacher-dashboard.t`, `t/dao/enrollment-transfer.t`. Twenty-two reference
`plan_scope`, `platform_pricing_plan_id` or `pricing_relationships`. Most are a one-line
constant change, but they have to be found, and the estimate for Leg 2 covers finding them
rather than the five `lib/` edits. One is not a constant change:
`t/lib/Test/Registry/Helpers.pm:79-99` resolves the platform plan by
`plan_scope = 'tenant'` and `die`s if no row comes back, then asserts exactly one
`pricing_relationships` row with the all-zeros `provider_id`. Both `t/user-journeys/alex/`
legs that call it `BAIL_OUT` on failure (`01-acquire-tenant.t:47`,
`03-platform-billing.t:50`), so this one helper aborts two whole files — and it is broken
twice over, by Leg 5's `plan_scope` → `audience` rename and by Leg 7 replacing
`pricing_relationships`. It gets rewritten against `Entitlement` in Leg 8, not patched
twice.

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
`transfers` is the destination-charge capability. The fixture moves to a v2 `Account` with
the Merchant configuration and `card_payments` only, matching the decision above — the
fixture and the runbook must name the same thing, and today neither of them names what
Leg 3 will build.

**Leg 3 needs a Connect webhook endpoint before it needs any code.** Events from a connected
account arrive at a Connect endpoint, which carries its own signing secret. Registry has
exactly one, read from `$ENV{STRIPE_WEBHOOK_SECRET}` at `Webhooks.pm:14` and `Payment.pm:141`
(and at `Client/Stripe.pm:18`, which Leg 1 deletes). Until a second endpoint and secret exist, a direct charge
succeeds at Stripe and Registry never hears about it — the same failure mode as the webhook
defect Leg 0 fixes, reintroduced by configuration. Register the endpoint and add the secret
first; the code is the easy half.

**And it needs two endpoints, not one, because v2 accounts split their events across
scopes.** Stripe: *"v2 `Account` objects trigger both v1 and v2 `Events`, which can have
different scopes. For events triggered by connected accounts, v2 `Events` use the **Your
account** scope, while v1 `Events` use the **Connected accounts** scope, even when triggered
by the same v2 `Account`."* So v1 `account.updated` and the direct charges arrive on the
Connect endpoint, and `v2.core.account.*` arrives on the platform endpoint as a thin event.
A Leg 3 that registers only the Connect endpoint will silently never see the v2 half.

**The tenant lookup Leg 3 needs does not exist yet.** An earlier draft said it was already
written and pointed at `Webhooks.pm:148-162`. That method does not resolve a tenant: it is a
blind `UPDATE registry.tenants … WHERE stripe_connect_account_id = ?` whose only output is
`->rows`, used to log a miss. It never produces the tenant identity — the slug — that a
payment handler needs to reach tenant-schema rows through `connect_schema`. Leg 3 writes that
lookup, and it is a `SELECT`, not a reuse.

## Testing

Strict TDD per `CLAUDE.md`; 100% pass rate; pristine output. Full suite is
`STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/` (~76 min).

**Seven of the fourteen legs add a migration, and `prove` will not see any of them.** Tests
build their database from a pre-generated dump: `Test::Registry::DB` loads
`sql/test-schema.sql` when it exists and only falls back to a sqitch deploy when it does
not (`t/lib/Test/Registry/DB.pm:13-16,63-68`). `make test` regenerates the dump because the
Makefile makes it a prerequisite (`Makefile:6,9-11`), but the `prove` invocation above —
the one this project actually types — does not. So a schema leg whose tests pass locally
proves only that the *old* schema still works. Every leg that touches `sql/deploy/` runs
`make test-schema` and commits the regenerated dump in the same commit as the migration;
a leg where `sql/test-schema.sql` is unchanged and `sql/deploy/` is not has not been
tested.

**Each migration also gets a revert test**, because sqitch reverts are the rollback plan
for a leg that goes wrong in production and Registry's revert scripts are not uniformly
honest — `sql/revert/pricing-plans-amount-cents.sql:9-14` and
`sql/revert/enhanced-pricing-model.sql:38-41` document data they cannot restore rather
than restoring it. Deploy, revert, deploy again, and assert the schema matches; where the
revert is genuinely lossy, say so in the script rather than pretending.

**And one test per dual-write window.** The windows are the riskiest thing in the
sequencing — Leg 5 through Leg 9 for `plan_scope`, Leg 7 through Leg 9 for
`platform_pricing_plan_id` — and the failure mode is silent: the second write is dropped,
the old reader finds nothing, and `RevenueShare` dies at charge time with a message about
a deployment bug. The test publishes a version through `PriceOps::Model` and asserts the
legacy row exists with the mapped `plan_scope`, so the window closing early fails in the
suite rather than at a parent's checkout.

One invariant test per pillar:

1. A published plan version cannot be updated — the trigger raises.
2. A quote resolved at time T returns the version in effect at T after a later version is published.
3. A zero-priced enrollment on a Free-tier tenant still writes a `metering_events` row.
4. No production code path reads a plan by name; the resolver rejects a version it cannot price.
5. A plan authored via CLI and one authored by the workflow are identical on the authored
   columns — not byte-identical, which no two rows with distinct `id`s and `created_at`s
   can be. The comparison names the columns: `provider_id`, `audience`, and every
   component's kind, cadence, currency and amount. A rateless percentage plan is rejected
   at authoring. This invariant assumes the workflow survives Leg 5; if Leg 5 deletes it,
   there is no second author and this becomes a CLI-only assertion — the rateless rejection
   and the constraint coverage, without the comparison.

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
last of all — after both, not with either. It lives in `t/stripe-live/`, which `prove -lr t/`
does run but which `plan skip_all`s without a real `sk_test_` key
(`t/stripe-live/paid-enrollment.t:30`) — so a green `make test` says nothing about it. The
gate is `.github/workflows/stripe-e2e.yml` being green, not the suite. Everything else in
this section runs in the normal suite against an ephemeral Postgres; the live test proves
only the one thing an ephemeral Postgres cannot, which is that Stripe moved money.

**That workflow cannot currently fail, and until it can, this milestone has no gate at all.**
Its own header says so — `.github/workflows/stripe-e2e.yml:2`: *"Informational only --
continue-on-error means failures never block merges."* Both real-Stripe steps carry
`continue-on-error: true` (`:83`, `:91`), and `main` has no branch protection rule, so a red
run is a red X nobody is required to look at. The design has spent fourteen legs arriving at
a single criterion that is first evaluated on a workflow structurally incapable of reporting
failure. **Removing `continue-on-error` and protecting `main` is part of Leg 3a**, not a
follow-up: it costs minutes, and every leg after it is worth less without it. The reason it
belongs in 3a specifically is that 3a is the first leg with a real-Stripe result worth
gating on.

The suite is not pristine today: `t/dao/scheduled-payment.t:22`,
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
- **Admin UI for authoring *platform* plans.** Pillar 5 is satisfied by `./registry pricing`
  plus CHECK constraints, which is Leg 11; a UI when a human who is not perigrin needs to
  author a platform plan. An earlier draft dropped the word "platform" and so read as though
  all authoring were out of scope, which contradicted Leg 5 sitting in the table. The two are
  different surfaces with different authors: the platform plan is perigrin's and the CLI is
  enough, while `pricing-plan-creation` is a *tenant's* path to authoring a program's prices
  and is in scope. Whether Leg 5 rewrites that workflow or deletes it is deliberately
  undecided until Leg 4 — see "Sequencing".
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
    disconnect and their fees are no longer ours to clear. **Half of this is superseded by
    (24):** the conclusion that disconnect is Registry-initiated survives and is now
    structural rather than a preference, but there is no revocation to order against and no
    deauthorized event to handle.
14. **Account configuration was an open decision for perigrin; it is now settled** — see
    (23), which both answers it and corrects the recommendation this item made.
15. **Creating the direct-charge subscription is work in this milestone, not an assumption
    of it.** `Subscription.pm:118-158` builds inline `price_data` on the *platform* account
    with no `application_fee_percent`; nothing today can create the recurring tenant→family
    charge the acceptance criterion describes. `PriceOps::Schedule` doing so lands in Leg 8.
    Without it the gate cannot pass, and the omission was invisible because every other leg
    described a table or a rewrite rather than a missing capability.

A fourth round found that several of the instructions above were not executable as written.
The pattern is consistent enough to name: this document had been good at deciding *what*
should be true and bad at naming *which function makes it true*.

16. **The `clone_schema` citation pointed at a file sqitch will never run again.** (5) and
    (9) both cited `sql/deploy/schema-based-multitennancy.sql`, which was superseded by
    `fix-clone-schema-identifier-quoting.sql` on 2026-06-10 (`sql/sqitch.plan:56`). Since
    sqitch does not redeploy a deployed change, an implementer who edited the named file
    would have changed nothing in any database and had no way to notice. Leg 4 ships a new
    change with `CREATE OR REPLACE FUNCTION`. Also: six copy loops, not five, and the skip
    list has to go in every one that names a table — a list applied to the table loop but
    not the trigger loop makes `clone_schema` raise `relation
    "<tenant>.pricing_plan_versions" does not exist` and hard-fails tenant onboarding.
17. **"Every `$self->update` becomes `save`" would corrupt paid rows.** `Payment::save`
    (`:425-435`) writes six columns from in-memory fields, and every `Payment` field is
    `:param :reader` with no writer — so the literal swap at `Webhooks.pm:136` would write
    back the `status` the object was constructed with and *un-complete a paid enrollment*.
    Leg 0 adds `mark_completed($db, $intent_id)` instead. Two reviewers found this
    independently.
18. **`update_billing_status` "has no caller in `lib/` at all" was false**, and contradicted
    the same paragraph that asserted it: all five subscription handlers call it
    (`Subscription.pm:277,293,311,324,337`). What it actually lacks is a *reader* — nothing
    consumes `tenants.billing_status`. Recorded because a wrong citation in a design document
    is worse than a missing one; it gets acted on.
19. **`plan_scope` is renamed to `audience`, not dropped.** An earlier draft said scope was
    implied by the provider. It is not: registry offers two disjoint menus with the same
    `provider_id` — tenant-scoped program plans (`unified-pricing-infrastructure.sql:112,138`,
    read by `PricingPlanSelection.pm:93,147`) and the platform revenue-share plan
    (`seed-free-platform-plan.sql:18`, read by `RevenueShare.pm:58-64,114-120`). The column
    answers "offered to whom", which the provider cannot. `Model->offered_versions` reads it.
20. **Dual-writing got an owner.** (8) said the deprecated columns "stay dual-written" and
    named no function to do it, which would have made the window close silently the moment
    Leg 5 rewrote the current writers. `PriceOps::Model->publish_version` owns it, and a test
    per window fails if it stops.
21. **Immutability needs three triggers, not one, and publishing has an order.** A version is
    only immutable if its children are, so `pricing_components` gets BEFORE UPDATE, BEFORE
    DELETE and BEFORE INSERT guards against a published parent. And the version trigger has to
    name the one transition it permits — NULL Stripe ids becoming non-NULL — or publishing is
    blocked by the immutability it depends on.
22. **Estimates are in sessions, not engineering days.** Every earlier draft costed the
    milestone in days — 37-55, then 52-72 after a review costed legs by the code they touch
    rather than the tables they name. perigrin's objection is that days are wildly inaccurate
    for this kind of work, and he is right: the unit assumed a fixed number of hours nobody
    sits down for, and it was never what the work arrives in. The unit is now one context
    window of focused work, 250k-500k tokens, cold start to commit. **33 to 49 sessions**
    after (24) added Leg 3a, and **32 to 51** after (29) and (30) — the ceiling raised by the
    money-path work, the floor lowered only by Leg 5 becoming a fork.
    The re-costing also changed the *shape* of the estimate, not just its units: work that is
    wide and shallow (Leg 2's 21 test files, Leg 5's 1,412 lines of templates) is expensive in
    sessions in a way it was not in days, because reading is what spends a context window,
    while a small careful change is cheaper than its risk suggests. Leg 0 was the example of
    that second point at 1-2 sessions and is no longer one: (30) gave it locking, a capacity
    re-check and logging across two modules, so it now costs what a leg with four unrelated
    concerns costs. The principle held; the example moved.
23. **Accounts v2, `losses`/`fees` to Stripe, full dashboard** — (14) is answered, and the
    recommendation it carried is corrected. "v1 accounts with controller properties" was
    wrong twice: controller properties are the migration path for platforms already on v1,
    and the claim that v2 "buys nothing this milestone needs" was backwards. A v2 `Account`
    carries Merchant and Customer configurations at once, which is this design's own
    "provider sells to consumer" relation expressed in Stripe's object model — and Registry
    is currently paying for the v1 version of it, maintaining a Stripe `Customer`
    (`Subscription.pm:59-64`) alongside the connected `Account`. Leg 3 collapses the pair.
    The configuration reproduces Standard's shape, which is what every property in this
    design already assumed: Stripe carries negative-balance liability and KYC, Stripe bills
    the tenant for processing fees with Registry's share on top as the application fee, and
    the tenant keeps a full Stripe Dashboard and Stripe's support — which matters because
    Registry is one person and the alternative makes him tier-1 support. The error was mine
    and no review caught it: every lens I ran pointed at Registry's code, none at Stripe's
    current documentation.
24. **(23) was right about the decision and wrong about four of its consequences**, all found
    by pointing the next review at Stripe's documentation instead of at Registry. The decision
    stands; these do not:
    - **Choosing v2 gives up OAuth.** Stripe lists *"OAuth to authenticate connected
      accounts"* among the cases where **"You must use Accounts v1."** This costs Registry
      nothing today — onboarding is done by hand in the Dashboard
      (`docs/operations/sacp-stripe-connect-onboarding.md:11-20`) and no module in `lib/`
      creates a connected account — but it removes `/v1/oauth/deauthorize` and
      `account.application.deauthorized`, which (13) had built the disconnect design on.
    - **"A v2 account uses the rejection API instead" was invented.** There is no revoke path:
      `/v2/core/accounts/{id}/close` returns `stripe_loss_liable_cannot_be_deleted` for
      exactly the configuration chosen here. Disconnect becomes Registry-side only, which is
      right — the account belongs to the tenant. The account-*initiated* half is now an open
      question for Leg 3a rather than a handler, because writing a handler for an event that
      may never fire is worse than admitting we do not know yet.
    - **`dashboard` was marked immutable and is not.** It is a parameter of
      `/v2/core/accounts/update`, and Stripe sends `v2.core.account.updated` *"only for
      updates to top-level properties, such as `dashboard` or `display_name`."* The row that
      might deserve the warning is `defaults.responsibilities`, and the reference does not
      settle it — so Leg 3a confirms it against a test-mode account rather than the spec
      guessing a second time.
    - **The API version pin makes all of this unreachable.** `Service::Stripe.pm:15` sends
      `2024-12-18.acacia`, which predates v2; Stripe's current v2 examples send `2026-07-29`.
      That bump is a change to every v1 call Registry makes and belongs in its own leg, which
      is what Leg 3a is.
25. **Leg 3a exists to move discovery in front of the deadline.** Leg 3 is the only leg that
    must merge before the first tenant onboards, and it had accumulated two items whose
    outcome could invalidate it: the version bump, and whether a chargeable full-dashboard v2
    account can be provisioned unattended. `t/lib/Test/Registry/StripeConnect.pm:79-113` gets
    one today only because `type: custom` makes the platform the requirements collector, and
    `dashboard: full` gives that job to Stripe. If there is no equivalent, the milestone's
    acceptance test cannot run unattended and `dashboard: full` has to be reconsidered — a
    finding that is cheap before Leg 3 and expensive after it.
26. **The milestone's only gate could not fail.** `.github/workflows/stripe-e2e.yml` carries
    `continue-on-error: true` on both real-Stripe steps and says so in its own header, and
    `main` has no branch protection. Fourteen legs converging on one acceptance criterion,
    evaluated by a workflow that cannot report failure. Fixed in Leg 3a, which is the first
    leg with a real-Stripe result worth gating on.
27. **The Customer-configuration collapse moves from Leg 3 to Leg 9.** It is the only part of
    Leg 3 with no deadline, and Stripe supports adding a configuration later without
    re-collecting requirements. It also joins the column it obsoletes:
    `tenants.stripe_customer_id` was already dropping in Leg 9. Named the mechanism while
    moving it — `customer_account`, not `customer` — because "collapses the pair" is not
    something an implementer can type.
28. **Four smaller corrections, recorded rather than quietly fixed.** `tenants.platform_
    pricing_plan_id` was described as **dropped** in the data model and dual-written
    everywhere else — a Leg 7 author reading only the data model would have broken collection
    for two legs. "Leg 0 ships alone and first" survived the renumbering that put Leg 1 ahead
    of it. The tenant lookup Leg 3 needs was said to be "already written" at
    `Webhooks.pm:148-162`; that method is a blind `UPDATE` returning `->rows` and yields no
    tenant identity, so Leg 3 writes a `SELECT`. And two counts were wrong: installments are
    ~3,000 lines, not ~3,700, and there are fourteen legs, not twelve.

Two more, both perigrin's calls rather than a review's findings:

29. **Leg 5 is rewrite-or-delete, decided after Leg 4.** The spec had the workflow rewritten
    in the leg table and the CLI declared sufficient under "Out of scope", which is a
    contradiction the completeness pass caught. Resolving it by picking now would have meant
    picking from a line count; the diff that settles it does not exist until the version and
    component tables do. So the fork is recorded rather than closed, with its criterion under
    "Sequencing" and a `0-4` range that says plainly that nobody has agreed to the work. The
    two branches are not symmetric: delete also rewrites acceptance invariant 5, which
    compares the workflow's output against the CLI's and has nothing to compare against once
    the workflow is gone.
30. **The bar moved from "PriceOps aligned" to "ready to take money."** Five findings sat
    outside PriceOps and inside the money path, and a correct pricing model over a charge path
    with no row locks and no logs would have been aligned and still not safe to switch on.
    Folded in rather than filed: row locking and a capacity re-check at capture, plus
    structured logging keyed on Stripe's `request_id`, into Leg 0; the quote's currency into
    Leg 9; the CSP widening into Leg 12; and the rollback subsection under "Money movement",
    which is the one with no leg because it is a property of how every leg deploys. Two
    sessions on the ceiling, 49 to 51.

    Two of those findings were narrower than first reported, and the narrowing is the useful
    part. **Currency is not dropped** — `Payment.pm:15` defaults it and `:195` writes it, so
    the column is populated; what is missing is a caller that ever *chooses* it, since the
    only non-installment one, `WorkflowSteps/Payment.pm:193`, passes none. A defaulted column
    looks identical to a correct one until the first CAD plan. And **double-submit is not
    unguarded** — #283's stale-intent checks are real and cited
    (`WorkflowSteps/Payment.pm:26-31,180-181,254-261`). The claim that survives is the
    narrower one: every guard is a read, then a decision, then a write, against a row nothing
    is holding, because `DAO/Payment.pm` contains zero `$db->begin` and zero `FOR UPDATE`.
    Both were worth keeping only once they were true.

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
- **Tenants can change their own payment-method settings** from their Stripe Dashboard — a
  direct consequence of `dashboard: full`. Under direct charges that is their right, and it
  means the payment methods a family is offered are not wholly ours to determine. Document
  it; do not fight it.
- **The Connect onboarding runbook names Standard accounts.**
  `docs/operations/sacp-stripe-connect-onboarding.md:3,11` documents a flow this milestone
  replaces — and since it is the *only* onboarding mechanism Registry has, rewriting it is
  not documentation tidying, it is how the new configuration actually gets used. It is
  operator-facing, so a stale one is worse than none: it will be followed. Rewrite it in
  Leg 3, against Accounts v2, in the same branch that changes the fixture.
- **`sql/verify/stripe-subscription-integration.sql:9` asserts `tenants.stripe_customer_id`
  exists**, and Leg 9 drops it. A sqitch verify script for an earlier change breaking on a
  later change is a deploy-time failure in the one place with no test coverage. Check it
  while writing Leg 9's migration.
- **Mixed-interval subscriptions may have superseded one of the four Stripe restrictions
  above.** The constraint that every item on a subscription shares `interval` and
  `interval_count` is stated here as absolute; Stripe has since added mixed-interval
  subscriptions under flexible billing mode. The design is *more* restrictive than Stripe
  requires, which is safe, so this is a possible simplification rather than a defect —
  confirm before Leg 8 designs the per-(version, cadence) CHECK around it.
- **A failed migration does not fail the deploy.** `docker-entrypoint.sh:20-24` warns and
  boots the app anyway, and `render.yaml:75`'s worker runs no migration at all. Not caused
  by this design, but seven migrations across fourteen legs make it much likelier to bite, and
  the failure mode is new pricing code querying a table that is not there. Its own issue,
  fixed before the first leg deploys.
