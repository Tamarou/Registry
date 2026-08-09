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
| 5. Tooling | absent | Every platform plan *in the database* is hand-typed SQL in a migration (`sql/deploy/seed-free-platform-plan.sql:24`, `sql/deploy/unified-pricing-infrastructure.sql:106,119,132`). The authoring workflow can write one — `PricingPlanBasics.pm:88-93` offers `platform` and `tenant` scopes, `PricingModel.pm:94-99` writes `percentage` — but nothing in production came from it, so the vocabulary the workflow writes has never been checked against the one the charge path reads. Two authoring paths, one of them exercised. This is why `percentage: 1` is ambiguous between 100% and a 1% typo and why `revenue_share_percent` drifted from `percentage`. `sql/deploy/suspend-rateless-tenant-plans.sql` is a one-shot UPDATE — exactly the out-of-band adjustment Pillar 5 exists to eliminate. |

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
(`PricingPlanSelection.pm:84-87`) and their choice is recorded somewhere else entirely.

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
   settled with an `application_fee_amount` **equal to the rate times the invoice total, to
   the cent** — not merely non-zero. A wrong-but-positive fee is exactly the `percentage: 1`
   ambiguity between 100% and a 1% typo, sailing through an assertion written to catch it.
3. **It makes the same assertion on the one-time path**, which point 2 does not reach. A
   subscription is created by `PriceOps::Schedule`; every enrollment Registry takes today
   goes through `DAO::Payment` and a PaymentIntent, and those are different code with a
   different fee parameter. So the test also enrolls against a `fixed`/`one_time` component
   and asserts a PaymentIntent on the tenant's account carrying the expected
   `application_fee_amount`. Without this the milestone can pass its own gate with ordinary
   checkout broken — and the three silent `return ()` guards in `_connect_params`
   (`Payment.pm:78,84,86`, on a missing tenant, a missing account and a zero fraction) are
   precisely how it would break: each one produces a working charge that pays Registry
   nothing.
4. It asserts the plan's name and slug appear in no file under `lib/`, `workflows/`,
   `templates/` or `sql/` — the grep that stands in for "no code change," and the same shape
   as the `price_data` assertion under "Testing". A plan whose name has to be taught to the
   code is a plan that failed Pillar 1. **The grep covers the plan's *shape* as well as its
   name**, because `templates/tenant-signup/pricing.html.ep:62-70` hardcodes plan shape —
   branching on `plan_type` to decide what to render — and a name-and-slug grep passes over
   it untouched.
5. **It replays.** The webhook that settles the invoice is delivered twice and the test
   asserts one payment row, one enrollment and one fee. Stripe retries on any non-2xx and
   the whole point of Leg 0 is that a retry heals rather than duplicates; an acceptance test
   that never redelivers has not tested the property the milestone's riskiest leg exists to
   establish. It needs a **unique index on `payments.stripe_payment_intent_id`** to assert
   against — `idx_payments_stripe_intent` (`sql/test-schema.sql:3950`) is not unique, so
   nothing in the database currently forbids the second row. That index lands in Leg 0.

Two Stripe properties make point 2 a race rather than a read, and both belong here rather
than in a Leg 11 surprise. **Application fees on direct charges are created asynchronously**
— Stripe: *"Application fees for direct charges are created asynchronously by default. If
you need to know when the fee is available, listen for the `application_fee.created`
webhook event."* So the test polls or waits on that event; retrieving the invoice the
instant it settles can legitimately show no fee yet, and a gate that flakes gets disabled.
`application_fee.created` and `application_fee.refunded` therefore join Leg 3's Connect
endpoint subscription list. And the test asserts **`livemode: false`** on every object it
touches, because the one failure this repository must never have is a green acceptance run
against real money.

**The `application_fee_amount` clause in point 2 currently fails, and that is the
criterion working.** The seeded platform default plan carries `"percentage": 0.00`
(`sql/deploy/seed-free-platform-plan.sql:24`), and `platform_default_fraction`
(`RevenueShare.pm:55-72`) reads exactly that plan — it dies loudly if the row is missing but
returns a perfectly valid zero if the row says zero. So a tenant with no linked plan is
charged 0%, `TenantPayment.pm:121-127` displays "0% of processed revenue" at signup, and two
marketing surfaces above it promise 2.5% (`templates/tenant-signup/index.html.ep:64`,
`templates/registry/tenant-storefront-program-listing.html.ep:93`). This is a known deferral,
not a discovery — `docs/specs/plan-driven-revenue-share.md:60,275,373` records the
2%-vs-2.5% choice as open and the fix as a one-line data edit. Naming it here because a
milestone called *ready to take money* cannot pass while the platform's share is zero, and
because the tempting way to make the test green is to link the fixture tenant to a 2% plan
and leave production at 0.00. **The fixture must not be given a rate production does not
have.**

**Setting the launch rate is a decision rather than work, but it cannot wait for Leg 11, and
an earlier draft said it could.** Leg 11 sits at position 13 of 14; Decision 3 says Leg 3
must merge *before the first tenant onboards*, at position 5. Nothing in the code enforces
an ordering between them — `revenue_share_fraction_for_tenant` (`RevenueShare.pm:25-72`)
reads `pricing_configuration->>'percentage'` fresh on every call with no caching, so the
0.00 simply keeps being returned. Follow both instructions literally and every tenant
onboarded after Leg 3 is charged nothing for eight legs, on a charge path that is otherwise
working correctly, which is the worst kind of revenue bug: it looks exactly like success.
So the rate is set **in Leg 3, alongside the deadline it shares**, as a one-line data
migration. Leg 11 keeps the *tooling* half — the CLI that makes the next change something
other than hand-typed SQL — which was always the part that was work.

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

**A write cutover with no reader cutover is worse than either, and this is the shape of the
milestone's most repeatable mistake.** Leg 4 as stated repoints `PricingPlan->create` at the
registry table and leaves every *reader* resolving `pricing_plans` through the tenant
`search_path` — `PricingPlan.pm:69-72` uses the unqualified name deliberately, and `find`
(`:88`), `find_by_id` (`:98-99`) and `get_pricing_plans` (`:126-133`) all inherit that. So
from Leg 4 until Leg 8 a newly priced program writes to `registry.pricing_plans` and the
charge path reads `<tenant>.pricing_plans`, finds nothing, and `Payment.pm:517-518`'s
`next unless $pricing_plans && @$pricing_plans` skips the child — enrolling them free.
Leg 0's refusal guard does not catch it: that guard fires on `defined $price_cents` at
`:528`, and the `next` at `:518` is two statements earlier. The readers move with the
writer. Three readers sit outside `PricingPlan.pm` and are named here because a grep for the
table name finds only two of them: `ProgramListing.pm:102` and `ProgramSetupOverview.pm:35`
write the SQL themselves, and `Session.pm:164-166` does not — `method pricing_plans` delegates
to `get_pricing_plans`, which is how `Payment.pm:517` reaches the table at all. The chain the
free-enrollment argument above depends on runs through a file the argument did not name.

The same shape recurs twice more and is called out at each site rather than left to be
rediscovered: Leg 6 publishes for tenants that cannot be published to, and Leg 7 drops
`pricing_relationships` while a live workflow still reads it. See "Sequencing".

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
the signup menu a tenant chooses from (three of them, at `unified-pricing-infrastructure.sql:106,119,132`,
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

**And the version needs a BEFORE DELETE of its own**, which the asymmetry above makes easy to
miss: components get three guards and the version got one, so `DELETE FROM
pricing_plan_versions WHERE id = …` removes a published version outright — cascading its
components past their own guards and orphaning every `payments.plan_version_id` stamp that
pointed at it. Append-only means no deletes, not no updates. Both tables also get
`REVOKE TRUNCATE`, because `TRUNCATE` fires statement triggers and skips row-level ones
entirely: a table protected only by BEFORE DELETE is one `TRUNCATE` from empty, silently.

**Publishing is N Stripe calls and one Postgres write, in that order.** A version with three
components is one Product call plus up to three Price calls, none of them transactional with
the database. If `published_at` were set first, a failure after component 1 would leave a
published version with NULL `stripe_price_id`s that the immutability trigger now refuses to
repair — permanently unschedulable and permanently unfixable. So: create the Stripe objects,
record every id, and set `published_at` last, gated on every component that *has* a Stripe
Price having recorded its id.

**"Up to three" and "every component that has a Price" are the load-bearing words, and an
earlier draft had neither.** It gated publication on *every* component holding a non-NULL
`stripe_price_id` and had `Entitlement` refuse to quote a version with any NULL. **A
`percentage` component has no Stripe Price and never will** — by this design's own
collection table it is collected as `application_fee_amount` on someone else's PaymentIntent
or `application_fee_percent` on someone else's Subscription, neither of which is a Price
object. Under the earlier rule, registry's own 2% plan — *"one row with `provider_id` =
registry"* — is unpublishable at Leg 6 and unquotable at Leg 8. That is not a corner case;
it is the platform's only plan, and the milestone's acceptance criterion runs through it.

So the rule is per-kind and stated as one: **`stripe_price_id` is required for `fixed`
components and must be NULL for `percentage` ones**, enforced by a CHECK rather than by the
publisher remembering. The publish gate and the resolver's refusal both read that CHECK's
condition rather than a bare NULL test. Getting this backwards in either direction is silent:
require a Price everywhere and the platform cannot sell; require it nowhere and a `fixed`
component with a failed Price call is schedulable and uncollectable.

`fixed`/`one_time` is a third case worth naming, because it needs no Price either — a
PaymentIntent takes a bare `amount`, and today's charge path builds one without a Price
object anywhere. It gets one regardless: publishing every `fixed` component as a Price is
what makes the catalog readable in the Stripe Dashboard and what lets a one-time component
be moved onto an Invoice later without a migration. The CHECK is on `kind`, not on cadence.

The payer-facing line item is generated from the component, not stored on it. A stored label
and a generator are two spellings of the same string that drift apart, which is #292.

Composition is the point. "One-time setup fee, monthly floor, percentage over that" is three
rows; registry's own 2% is one row with `provider_id` = registry. No count is special-cased
and no combination of the existing kinds requires code — **at the model layer.** The
qualifier matters: a *model* that composes freely can still describe something Stripe cannot
collect in one object, and "2% plus $20/month" is exactly that case. It is two legal rows
that need an `invoice.created` handler to collect, which is the deferred hybrid under
"Collection mechanisms". An earlier draft used that pair as the headline example of free
composition on one page and listed it as out of scope on another. Both statements were true
of different layers and the contradiction was in eliding which. **Authoring a hybrid is
therefore refused at publish**, by the same CHECK that owns the kind rules, until the handler
exists — a model that lets you author an uncollectable plan is Pillar 1 failing quietly.
A new *kind* is a different matter again — see "Collection mechanisms".

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
`(provider_id, consumer_tenant_id, coalesce(consumer_user_id, '00000000-0000-0000-0000-000000000000'::uuid),
tstzrange(effective_at, ends_at))` where `status = 'active'` makes an overlapping schedule
unwritable. Without it, "the schedule in effect at `at`" is a convention that holds until the
first backdated correction.

**That constraint does not currently compile, and the way it fails is the worst available.**
Two extensions it needs are absent: `grep -rn "CREATE EXTENSION" sql/` returns nothing in
this repository. GiST cannot index a `uuid` for equality without **`btree_gist`**, so the
`CREATE TABLE` raises `data type uuid has no default operator class for access method
"gist"`; and `uuid_nil()` belongs to **`uuid-ossp`**, which is why the literal is spelled out
above rather than called. So Leg 7's migration opens with
`CREATE EXTENSION IF NOT EXISTS btree_gist` and the coalesce sentinel stays a literal — one
dependency instead of two. The failure matters because `docker-entrypoint.sh:20-24` warns on
a failed `sqitch deploy` and boots the app anyway: the constraint would simply not exist in
production, overlapping schedules would be writable, and the resolver would silently pick one
of two rows. A constraint that is the *only* thing making a fact a fact must be verified to
be there, which is what Leg 7's `sql/verify/` script is for.

One collision to note while writing it: the all-zeros UUID is what Leg 2 retires as a
*tenant* identity. Reusing it here as a "no user" sentinel inside a `coalesce` is a different
job — it is never stored and never compared to a tenant — but it is the same literal, so
Leg 2's grep will find it and Leg 7's author has to know it is deliberate. The alternative,
a partial exclusion constraint per nullability case, is two constraints to keep in agreement.

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

**The boolean also needs somewhere to be stamped *from*, and the model as specified has
nowhere.** Every field of `pricing_configuration` was given a successor except this one:
`percentage` becomes a component's `rate`, `monthly_amount` becomes a `fixed`/`recurring`
component's `amount_cents`, and `refund_application_fee` becomes nothing. So
`pricing_plan_versions` carries **`refund_application_fee boolean NOT NULL DEFAULT true`**
— it is a property of the terms sold, not of a component, which is why it sits on the version
beside `requirements` rather than being repeated per row. The Quote carries it through and
Leg 9 stamps it.

**And the resolver cannot read a stamp with the signature it has.**
`refund_application_fee_for_tenant($db, $tenant_slug)` (`RevenueShare.pm:87`) takes no
payment and therefore cannot reach the row the policy was stamped on — it reads
`pricing_configuration->>'refund_application_fee'` live at `:92`, which is the defect. Its
name is an operational contract (`docs/operations/sacp-stripe-connect-onboarding.md:202`)
and the name survives, but **the signature does not**: it becomes
`refund_application_fee_for_payment($db, $payment)` in Leg 9, reading the stamp, with the
tenant-slug form deleted in the same commit rather than left as a wrapper that would keep
resolving forwards. This is the one place in the design where "keeps their names and
signatures" under "Resolution" is wrong, and it is wrong for the reason the whole section
exists.

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

**`payments` is a tenant-schema table, and every migration in this design that touches it
needs a per-tenant loop.** This is the single most likely way a leg here ships broken, and
the deadline leg is one of the two that does it. `ALTER TABLE registry.payments ADD COLUMN
stripe_account_id` gives the column to the `registry` copy and to every tenant onboarded
*afterwards*, because `clone_schema` copies structure at call time — and to no tenant that
already exists. Those tenants keep charging against a table with no routing column while the
code writes one, which is a runtime error on every enrollment in their schema. The house
pattern is already written and is followed verbatim:
`sql/deploy/payments-amount-cents.sql:30-54` loops
`FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry'` with a
`CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = s)`
guard for tenants with no schema of their own, and its comment says why. Both Leg 3's
`stripe_account_id` and Leg 9's quote columns take that loop.

It is worth knowing that **no test will catch its absence.** `sql/test-schema.sql` contains
`registry`, `sqitch` and `public` and no tenant schema at all, so the loop body never
executes under `make test-schema` and a migration that omits the loop entirely passes the
suite. The tenancy invariant test under "Testing" — which onboards a tenant — is the only
thing in the design that would notice, and it is extended to assert the column set of
`<tenant>.payments` matches `registry.payments` for exactly this reason.

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

Two things about that change cost more than "add a skip list" suggests, and both are the kind
of thing discovered at deploy time. It must declare
`requires=fix-clone-schema-identifier-quoting` in `sql/sqitch.plan`, or sqitch is free to
order it before the change it forks from and the newer definition is silently overwritten by
the older one. And its **revert is a second full copy of the function** — the body is 484
lines — because reverting `CREATE OR REPLACE` means replacing it back, and an empty revert
here leaves a reverted database running Leg 4's cloning behaviour. That is the largest single
revert script in the milestone and it is not optional under the rule below that every
migration ships a tested one.

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
- `DAO/PricingPlan.pm:69-72` deliberately uses the **unqualified** table name, with the
  comment saying so: *"This allows both the registry schema and tenant schemas to store
  pricing plans in their own pricing_plans table."* `find` at `:88`, `find_by_id` at
  `:98-99` and `get_pricing_plans` at `:126-133` do the same.
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
and says so in its ABOUTME. There is exactly one precedent for that in the repository —
`sql/revert/pricing-plans-amount-cents.sql:9-14`, which names the rounding it cannot undo.
An earlier draft cited `sql/revert/enhanced-pricing-model.sql:38-41` beside it as a second
example of the house style, and that was backwards: those lines are
`DELETE FROM %I.pricing_plans WHERE ctid NOT IN (SELECT MIN(ctid) … GROUP BY session_id)`,
which silently destroys every plan but one per session, under a comment that describes the
mechanic and never mentions the loss. It has no ABOUTME. It is the counterexample, and it is
what "document lossiness rather than pretending" is written against.

`pricing_plans.session_id` survives this. It is not scope and not type — it is the link from
a plan to the product it prices, and it is what makes Resolution step 2 ("the product's own
plan version") resolvable at all. It stays on `pricing_plans`, nullable, and is how a
transactional enrollment quote finds its components when no schedule row governs.

**Moving `pricing_plans` up to `registry` turns `session_id` into a cross-schema pointer, and
it loses its foreign key in the process.** `sessions` is a tenant-schema table; a
registry-schema `pricing_plans` cannot reference it, for the same reason `payments.plan_version_id`
cannot point back the other way. So `session_id` becomes a bare `uuid` — no FK, no cascade —
and the pair `(provider_id, session_id)` is what identifies the product, with `provider_id`
naming the schema the session must be resolved in. That is the identical treatment
`consumer_user_id` gets above and for the identical reason, but it arrives by a different
route and is easy to specify away: a Leg 4 author copying rows up will carry the FK definition
along with them and the migration will fail, which is the good case. The bad case is
`ON DELETE CASCADE` being carried across, where deleting a tenant's session silently deletes
another schema's pricing row. Leg 4's migration states the column as unconstrained explicitly.

**The exclusion is every loop that names a table, and it lands in Leg 4.** In
`fix-clone-schema-identifier-quoting.sql`, `clone_schema` copies sequences (`:318-356`),
tables (`:359-381`, with a nested column-default loop at `:369-378`), foreign keys
(`:384-396`), functions (`:399-408`), triggers (`:411-457`) and views (`:460-474`), and
`set_config('search_path', dest_schema, true)` means an unqualified reference inside any of
them resolves to the *destination* schema. Every table-shaped loop needs the same skip list
or the table arrives without its constraints instead of not arriving. It ships in Leg 4
alongside the tables themselves, not in Leg 7: a tenant onboarded between those two legs
would otherwise be born with clones nobody expects.

**The functions loop is exempt from the skip list and is not exempt from the problem.** It
copies routines rather than tables, so nothing about it needs a table name — but it copies
them *into the destination schema* under that same `search_path`, which means the four
immutability trigger functions Leg 4 writes get a private per-tenant duplicate with their
`registry.` qualifiers stripped. Each copy then resolves `pricing_plan_versions` to a tenant
table that the skip list guarantees does not exist, and the first tenant onboarded after
Leg 4 gets four functions that raise on call. Nothing calls them, because their triggers were
skipped, so this is dead weight rather than an outage — until someone reads one and believes
it. The fix is to **create the trigger functions in `public`, not `registry`**, and have the
triggers name them fully-qualified: `public` is not a source schema for the copy loop, so
there is nothing to duplicate. That is a one-word decision at authoring time and an awkward
migration afterwards.

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
two do not stack, so the handler computes one number from the Quote. It also carries a cost
worth knowing before signing up for it — *"If Stripe fails to receive a successful response
to `invoice.created`, then finalizing all invoices with automatic collection is delayed for
up to 72 hours"* — so a bug in that handler stalls every tenant's billing, not just the
hybrid plans'.

**"No named consumer" was the reason for deferring it and the reason is wrong.** Stripe:
*"The `application_fee_percent` parameter doesn't apply to invoices you create outside of a
subscription billing period. For example, it doesn't apply to proration invoice items that
are immediately invoiced."* Prorations are not a hybrid-plan feature; they are what a
subscription does when a family upgrades mid-month, changes a quantity, or cancels and is
credited. They arise from the pure-percentage case that **ships**, and every one of them
collects nothing for Registry while looking exactly like a working charge. That is the same
revenue hole (12) was written to close, one billing event further in.

The deferral survives, narrowed and with the consumer named. The `invoice.created` handler
still waits — it is the 72-hour-stall handler and it is not something to ship in the same leg
as the subscription itself — but **the milestone does not get to be unaware of prorations**.
Two things ship instead. `PriceOps::Schedule` sets `proration_behavior: 'none'` on the
subscriptions it creates, so a mid-cycle change produces no uncollected proration rather than
a silent one; the family is billed the new rate from the next period. And the follow-up list
carries the handler with its actual trigger, which is *the first tenant who wants mid-cycle
upgrades*, not *the first tenant who wants a hybrid plan*. Choosing `none` is a product
decision as much as a technical one and it is recorded as such: it is the option that cannot
lose money quietly, and the one to revisit deliberately.

Five Stripe restrictions bind the shipping half and belong in the design rather than in a
Leg 8 surprise:

- **`application_fee_amount` is omitted, never zero.** A Free-tier quote produces no fee
  parameter at all; the code path for "no fee" is absence, which is the same
  absence-versus-zero discipline the resolver enforces one layer up.
- **The platform cannot update or cancel a subscription it did not create**, nor add an
  `application_fee_amount` to an invoice it did not create, **nor to an invoice that contains
  invoice items the platform did not create**. The last clause was omitted from an earlier
  draft and it is the operative one under `dashboard: full`: a tenant who adds a single
  line item to an invoice from their own Dashboard makes that invoice permanently
  un-fee-able by us. Registry must be the creator of every tenant→family subscription,
  which it is — `PriceOps::Schedule` creates them — but it cannot be the sole author of
  every line on every invoice, and no code change makes it so.
- **Only connected accounts with full-Dashboard access can manage their customers'
  subscriptions.** This is a constraint on the account configuration, not on us; see
  "Account configuration" below. Its other edge is that a full-Dashboard tenant **can cancel
  or modify the subscriptions Registry created on their behalf**, from a UI Registry does not
  control and with no obligation to tell us. That is the correct trade — the account is
  theirs — but it means `customer.subscription.updated` and `.deleted` on the Connect
  endpoint are not optional bookkeeping: they are the only way Registry learns that a
  membership it believes is active has stopped paying. Those handlers are Leg 8's, with the
  subscription envelope dispatch below.
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
`application_fee_percent`, and the tenant owning the dispute. Had `dashboard: none` been
chosen instead, embedded onboarding, account management and the notification banner would
have become *mandatory* and moved into Leg 3 — which is the main reason not to choose it.

**It does change Leg 12, and an earlier draft had the argument backwards.** That draft said
embedded components work regardless of dashboard type, "so Leg 12 is unaffected." Stripe
frames them conditionally in the other direction: *"If your connected accounts **don't** have
access to the full Stripe Dashboard…"* is the case embedded components exist to serve. Under
`dashboard: full` a tenant already has Stripe's own dispute UI, with Stripe's support behind
it, and Leg 12 rebuilds a worse version of it inside Registry. Leg 12 is not *blocked* — the
components do render — it is **duplicative**, which is a different problem and a cheaper one.

The leg stays, narrowed to what the Stripe Dashboard cannot do: show a tenant their disputes
*next to the enrollment and the family they belong to*. Registry knows which child's
registration a disputed charge was for and Stripe does not, and that join is the entire value.
So Leg 12 is a list view keyed on `charge.dispute.*` data Registry already records in Leg 3,
with a deep link out to the Stripe Dashboard for the evidence submission itself — rather than
an embedded component reimplementing submission. That is a smaller leg than the one costed,
and the estimate is unchanged only because the AccountSession and CSP work it shares with
future embedded surfaces stays either way. Revisit if `dashboard` ever moves.

### Resolution

```
Registry::PriceOps::Entitlement->quote($db, { provider, consumer, product, at, quantity }) -> Quote
```

**`quantity` is in that signature because an earlier draft dropped it and called the result a
simplification.** Both live pricing paths take a child count today —
`DAO/PricingPlan.pm:171` reads `$context->{child_count} // 1` and
`PriceOps/PricingPlan.pm:89,110,114` threads it through — and `requirements_met` branches on
it for the `family` plan type. A resolver that cannot be told "three children" cannot price a
sibling enrollment, which is not an edge case in an after-school business; it is the common
case. The generic name is deliberate: the pricing layer prices *units of the thing being
sold*, and whether a unit is a child, a seat or a location is the product's question.

The honest consequence, recorded rather than smoothed over: **sibling discounts stop being
expressible.** Today `Family::sibling_discount_eligible` and the sibling calculator implement
"first child full price, subsequent children less" — a per-unit price that varies with unit
index, which neither `fixed` nor `percentage` describes and which "What gets deleted" removes
without saying what replaces it. Nothing replaces it. `tiered` is the kind that would, and
`tiered` is out of scope. So a tenant who wants sibling pricing after this milestone cannot
have it until that kind is added, and the migration must not silently convert an existing
sibling plan into a flat one — Leg 4 refuses to migrate a plan whose `pricing_configuration`
carries sibling terms, loudly, rather than quietly repricing somebody's programs. No tenant
has one today, which is why this is a documented limit rather than a blocker, and it is the
clearest single argument for `tiered` being the next kind added.

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

`RevenueShare::revenue_share_fraction_for_tenant` keeps its name and signature —
`docs/operations/sacp-stripe-connect-onboarding.md:183` names it by fully-qualified package
as a live operational contract — and becomes a thin wrapper over
`quote(provider: registry, consumer: tenant)`. `refund_application_fee_for_tenant` keeps the
first and loses the second, for the reason given under "Quote columns on `payments`": a
function that takes only a tenant slug cannot read a stamp, and reading the stamp is the fix.
It becomes `refund_application_fee_for_payment($db, $payment)` and the runbook is updated in
the same commit, since an operational contract that is wrong is worse than one that changed. `_coerce_pct`'s guard tightens
from `$raw <= 1` to `$raw <= 0.5`, with a message naming both readings, so the ambiguous
`1` fails at plan authoring rather than at payout.

**Refunds resolve backwards, not forwards.** A refund prices an event that already happened,
so `refund_application_fee_for_tenant` reads the terms stamped on the payment row rather
than quoting afresh. `Payment.pm:114` resolves from the tenant's *current* plan today, which
is why moving a tenant between plans rewrites the refund policy of every charge they have
ever taken. Quoting a refund is the same bug in a new resolver; reading the stamp is the fix.
This is the one place the quote is a read rather than a write, and it is the reason the quote
columns exist.

**`Entitlement` is named for Pillar 4 and implements half of it.** Pillar 4 is
*entitlement checking* — a feature flag keyed on a customer and a feature identifier,
answering "may this customer do this thing," resolved through the schedule and the model so
that application code never branches on a plan name. What `Entitlement->quote` answers is
"what does this cost," which is the *pricing* half. It satisfies the pillar's stated
constraint — no caller learns a plan name or version — and it does not satisfy the pillar's
stated purpose, because there is no `->allows($feature)` and nothing calls one.

That is the right scope and it should be recorded as scope rather than achievement. Registry
has no gated features today: `grep -rni entitle lib/` returns nothing, and `limits` and
`seats` appear in `lib/` only in two unrelated comments
(`WorkflowSteps/ResourceAllocation.pm:38`, `WorkflowSteps/ValidateTargetCapacity.pm:2`). Every
tenant can do everything; only the rate differs. Building a flag layer with no flag behind it
is the speculative generality this design refuses elsewhere. But the class is named
`Entitlement` and the milestone is described as aligning to the pillars, so an outside reader
would reasonably conclude Pillar 4 is done. It is not: **the milestone lands Pillar 4's
constraint and defers its capability.**

There is exactly one hint of the capability in the codebase, and it is worth naming so the
deferral is not mistaken for the question never having come up. The seeded
`Registry Standard - $200/month` plan carries
`"includes": ["unlimited_programs", "unlimited_enrollments", "email_support"]`
(`unified-pricing-infrastructure.sql:124`) — a feature list, which is Pillar 4's vocabulary.
Nothing reads it. The only occurrence of `unlimited_programs` outside that migration is a
fixture in `t/dao/pricing-plan-clean-architecture.t:160`, which is the test from #296 that has
never executed. When a tier does need limits, `includes` is the shape it wants and
`->allows($feature)` is a method on this same class reading this same schedule — which is the
argument for the name staying.

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

  **"Matched by their idempotency token" is not an operation Stripe offers**, and the design
  said it as though it were. An idempotency key is a request-deduplication header; it is not
  a field on the PaymentIntent, it is not returned in the object, and there is no
  `GET /v1/payment_intents?idempotency_key=…`. A job told to match on it has nothing to call.
  What *is* searchable is `metadata`, so the token is written there at creation —
  `metadata[registry_idempotency_token]` alongside the `tenant_slug` and payment id
  `_stripe_metadata_params` (`Payment.pm:51`) already sends — and the job uses Stripe's search
  API against that. That is a **Leg 0** change even though the job is Leg 12: metadata is only
  present on intents created after it ships, so every charge taken in the intervening legs is
  unmatchable if the write waits for the reader. Writing a field early is free; backfilling it
  onto Stripe objects is not possible at all.
- **Charge model.** Tenant→family moves to direct charges on the tenant's connected
  account, per "Whose Stripe account" above. `_connect_params` (`Payment.pm:74-98`) stops
  sending `transfer_data[destination]` and `on_behalf_of`; `application_fee_amount` is
  unchanged. The header itself is three lines in one place —
  `Service::Stripe::_request_async` builds headers at `:27-32` and every method routes
  through it. The Payment Element **gains** `stripeAccount`
  (`templates/summer-camp-registration/payment.html.ep:144`) — an earlier draft said it "is
  initialised with" it, in the present tense, and the string appears nowhere in the codebase;
  `:144` is a bare `Stripe('<%= $step_data->{stripe_publishable_key} %>')`. It keeps
  using the *platform's* publishable key, so no per-tenant key is needed. Families become
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
  `refund_application_fee_for_payment` costs the tenant money, not us, which is why it reads a
  stamped quote rather than a mutable plan. One behavioural difference to carry into the
  re-cut suite: a direct-charge refund can come back `pending` when the connected account's
  balance will not cover it, where a destination-charge refund on the platform's own balance
  normally would not. `succeeded` is not the only success, and a test asserting it is a test
  that will go red in production rather than in CI.
- **An approved refund never reaches Stripe today, and no leg here fixed that.** The design
  spends four bullets on how refunds *should* be issued and never checks whether anything
  issues them. `DropRequest.pm:68` writes `refund_status => 'pending'` when an admin approves
  a drop, and that is the end of the story: `Payment->refund` and `refund_async` have **zero
  callers anywhere in `lib/`** — every caller in the repository is a test — there is no Minion
  task that scans for pending refunds, and no code path transitions the column past
  `'pending'`. So the first parent who is approved for a refund is told they have one, the
  admin UI agrees, and the money stays with the tenant until somebody notices. This is a
  certain loss on the first drop-with-refund of a paid enrollment, it is invisible in tests
  because the DAO method is well covered in isolation, and it predates this milestone.
  It lands in **Leg 3**, with the charge model, because that is the leg that rewrites the
  refund parameters anyway and because a milestone called *ready to take money* cannot ship
  a refund button that does nothing. The shape is the one already used elsewhere: a
  `Registry::Job::ProcessRefunds` claiming `refund_status = 'pending'` rows with
  `FOR UPDATE SKIP LOCKED`, calling `refund` with the idempotency key from the bullet above,
  and moving the row to `refunded` or `refund_failed` on the answer.
- **`seti_test` provisions a real tenant on a subscription that will never bill.**
  `TenantPayment.pm:43,295` accepts a client-supplied `setup_intent_id` beginning with
  `seti_test` and, on that string alone, completes signup with a synthetic `sub_test_…`
  subscription id. The step runs on the public unauthenticated signup funnel and there is no
  `MOJO_MODE` or environment guard on it — the branch is live in production. Anyone who can
  read the form can create a fully-working tenant that Registry never charges. It is a test
  affordance in production code, which `CLAUDE.md` forbids outright, and it belongs in the
  same category as the `!$ENV{STRIPE_SECRET_KEY}` bypass Leg 8 deletes. **Leg 1 deletes it**
  and moves what the tests need into `t/lib/`, where test infrastructure is supposed to live.
  Leg 1 rather than Leg 8 because it is a deletion with no dependency on anything, and
  because every day it survives is a day the funnel is open.
- **Registry→tenant billing failures are a `warn` and an `undef`.** `DAO/Subscription.pm:98-99`
  ends its error path with `warn … ; return;`, so a failed platform subscription call produces
  a line on STDERR and a caller that cannot distinguish failure from an empty result. The
  same module's user agent sets no timeouts and sends no `Stripe-Version` — `Service/Stripe.pm:29`
  is the only place in the codebase that sends one at all. This is the *platform's own
  revenue* path, and the structured-logging item in Leg 0 names only `DAO/Payment.pm` and
  `Service/Stripe.pm`. `DAO/Subscription.pm` joins that list: same `request_id` keying, same
  die-rather-than-return-undef discipline, and the timeouts and version header that
  `Service::Stripe` already has. It is a third file in a leg that already owns two.
- **A re-registering parent is charged and then not enrolled, and the fix is one index.**
  `enrollments_session_student_type_unique` (`sql/test-schema.sql:2913`) is status-blind: a
  parent whose child dropped a session and is signing up again violates it. Stripe has
  captured by the time `create_for_payment` runs, so the insert raises, the webhook returns
  500, and Stripe retries the same event for three days against the same guaranteed failure —
  money taken, no enrollment, and a poison event in the queue. The repository already knows
  this: the comment at `Enrollment.pm:73-97` names this exact case as the reason its
  `ON CONFLICT` clause has an explicit arbiter rather than a bare `DO NOTHING`. Naming the
  arbiter was the right call and it does not fix the underlying constraint, which should be
  partial on active statuses. **Leg 0**, with the other things that make a paid enrollment
  survive its own webhook.
- **A blocking Stripe call inside the webhook transaction holds a row lock across the
  network.** Leg 0 makes `stripe()` a single transaction and adds `SELECT … FOR UPDATE` on the
  payment row; the handler within it retrieves the intent from Stripe, and
  `Service::Stripe`'s GETs are synchronous with a 30-second request timeout (`:22`). So the
  worst case is a payment row locked for thirty seconds while Postgres holds a connection
  open, and Stripe's own retry arriving in the meantime blocks behind it. Neither is a
  correctness problem — that is what the lock is for — but it is a throughput ceiling worth
  writing down rather than discovering under load: **the transaction does the minimum Stripe
  work, and anything that can be done before `begin` is.** In practice the intent is
  retrieved first and the transaction opened around the database work only, which costs
  nothing and is easy to write the other way round by accident.
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
- **Leg 3a's version bump breaks every invoice handler, silently, and that is the argument
  for 3a existing.** Stripe's `2025-03-31.basil` release removed `subscription`,
  `subscription_details`, `quote` and `subscription_proration_date` from the Invoice object,
  replacing them with `invoice.parent.subscription_details.subscription`; the same release
  removed `type`, `subscription`, `subscription_item`, `invoice_item`, `proration` and
  `proration_details` from InvoiceLineItem. Registry reads the removed field in **five**
  places — `Subscription.pm:316,329`, `Controller/Webhooks.pm:213`, and
  `PriceOps/ScheduledPayment.pm:23,51` — and every one of them is followed by
  `return unless $subscription_id`. So the field becomes `undef`, the guard fires, and the
  handler returns success having done nothing. No exception, no log line, no failed webhook
  for Stripe to retry: renewals simply stop being recorded while the dashboard shows every
  event delivered `200`. Two of the five die with Leg 1's installment deletion; the other
  three are rewritten in **Leg 3a**, in the same commit as the version bump, because a bump
  that lands without them is worse than no bump at all. This is the single best illustration
  of why the pin was moved into its own leg ahead of the deadline.
- **v2 thin events are not shaped like v1 events, and the existing handler would throw on
  one.** Leg 3 registers a platform endpoint for `v2.core.account.*`, and a v2 event body is
  `{"object": "v2.core.event", "type": …, "related_object": {"id": …, "url": …}}` — there is
  no `data.object`, by design: a thin event carries a pointer and the payload is fetched.
  `Controller::Webhooks` reads `$event->{data}{object}` unconditionally, so the first v2
  event to arrive dereferences `undef` and 500s, which Stripe then retries. Leg 3's second
  endpoint therefore needs its own parse-and-dispatch path calling `fetchEvent` /
  `fetchRelatedObject`, not a new `elsif` in the existing chain. Registering the endpoint
  without that is strictly worse than not registering it, because it converts "we never hear
  about v2 events" into "we 500 on every v2 event."
- **The payment row's currency is always `'USD'`, and no caller has ever chosen it.**
  `Payment.pm:15` declares `field $currency :param :reader = 'USD'` and `:195` writes it, so
  the column is populated — this is not a dropped value. But the only non-installment caller,
  `WorkflowSteps/Payment.pm:193`, passes no `currency`, so the default is the value every
  time. That is invisible today and wrong the moment a plan bills in two currencies, which
  this design explicitly supports. The quote knows the currency; Leg 9 is where it reaches
  the row, alongside the other quote columns.
- **An unpriced child is silently free today, and "refuse-not-zero" is not a principle here,
  it is a live bug.** `DAO/Payment.pm:522-524` calls `calculate_price({ date => time(), ... })`,
  passing an epoch integer. `PricingPlan.pm:152-166` then compares that integer against a
  cutoff string with the hyphens stripped: `2026-09-01` becomes `20260901`, `time()` does not
  match the `YYYY-MM-DD` regex so it stays ~1.78e9, and `$today > $cutoff` is true. It has
  been true since August 1970 and always will be. So `requirements_met` returns 0 for every
  `early_bird` plan, `calculate_price` returns bare `undef`, and `calculate_enrollment_total`
  reaches `if (defined $price_cents)` and **skips the child** — contributing nothing to
  `$total`. A session whose first plan is early-bird enrolls every child for free, through
  the live path at `WorkflowSteps/Payment.pm:38,68,113`. The same field has a second reader,
  `is_early_bird_available` at `:181-193`, which parses the string to an epoch and gets it
  right; two conventions for one column, one of them on the money path.

  Leg 8 fixes this by deleting `calculate_enrollment_total` outright, but Leg 8 is most of
  the milestone away, and this is live now. **Leg 0 takes the refusal half only**: an
  undefined price is not a zero price, so `calculate_enrollment_total` refuses rather than
  skipping. That preserves a genuinely free program — `calculate_price` returning `0` — and
  ends the silent one. The comparison bug itself gets an issue and dies with the module in
  Leg 8; there is no reason to repair a date parser scheduled for deletion.
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

The `registry.pricing_relationships` **table** outlives its modules by two legs. Nothing
writes it after Leg 7, but `PricingPlanSelection.pm:10,84,139` still reads it until Leg 8
repoints that step, so the `DROP TABLE` is Leg 9 — see "Sequencing".

`registry.billing_periods` and `DAO::BillingPeriod` are dropped in the same migration, and
the reason is a foreign key rather than a preference:
`billing_periods.pricing_relationship_id` references `registry.pricing_relationships(id)`
(`sql/test-schema.sql:4431`). Dropping `pricing_relationships` without dropping
`billing_periods` first fails, so the two go together — which is why the table drop moving
to Leg 9 takes `billing_periods` with it. `DAO::BillingPeriod` itself is dead and can go in
Leg 7 with the other modules.

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
six to nine times Leg 10 and that Legs 3, 4 and 8 are where the milestone lives; the absolute count
is the weaker claim. Ranges are wide where a leg's cost depends on how much of the E2E suite
has to be re-cut rather than extended.

| Leg | Content | Depends on | Sessions |
|---|---|---|---|
| 1 | Safe deletions: installments, `Client::Stripe`, `PriceOps/PricingPlan.pm`, misfiled tests, #296, discount form | — | 2-3 |
| 0 | The money path becomes atomic and observable: webhook atomicity in one transaction on one connection (**#247** is a prerequisite, not a follow-up); `update` → `save` via a mutating `mark_completed`; **`SELECT … FOR UPDATE` on the payment row so the #283 stale-intent guards hold under concurrency**; **capacity re-checked at capture**; **structured logging in `DAO/Payment.pm` and `Service/Stripe.pm` keyed on Stripe's `request_id`**, and the two silent `->catch(sub {})` blocks closed; **`calculate_enrollment_total` refuses an undefined price instead of skipping the child**, which is the live free-enrollment path; **a `Job::ProcessRefunds` so an approved refund reaches Stripe at all**; **a unique index on `payments.stripe_payment_intent_id`**; **`metadata[registry_idempotency_token]` on every Stripe object Registry creates**, which cannot be backfilled later; **the revert-test harness** the whole milestone then uses | 1 | 4-5 |
| 2 | **#294**: collapse `registry-platform` into `registry`; retire the all-zeros UUID as a provider identity, in `lib/` **and 21 test files including `t/lib/Test/Registry/Helpers.pm`** | 1 | 2-3 |
| 3a | **Bump `Stripe-Version` off `2024-12-18.acacia` to a v2-aware version**, in `Service::Stripe.pm:15`, `t/stripe-live/service-version.t` and `DAO::Subscription.pm:71-103` (which sends none); **spike a chargeable full-dashboard v2 account in test mode** and report whether `t/lib/Test/Registry/StripeConnect.pm`'s KYC path has an equivalent; confirm whether `defaults.responsibilities` is updatable; **rewrite the five `invoice.subscription` readers the `2025-03-31.basil` release breaks** — `Subscription.pm:316,329`, `Controller/Webhooks.pm:213`, `PriceOps/ScheduledPayment.pm:23,51`, each followed by a `return unless`, so the bump silently stops every invoice handler; remove `continue-on-error` from `stripe-e2e.yml` and protect `main` | 1 | 3-4 |
| 3 | Charge model: **Accounts v2 (`losses`/`fees` = `stripe`, `dashboard` = `full`)**; `Service::Stripe` gains a JSON `/v2/` branch; tenant→family becomes direct charges; `Stripe-Account` in `Service::Stripe` (refusing, not falling back); refunds lose `reverse_transfer` and gain an idempotency key; `charge.refunded` and dispute-*recording* handlers; multi-`v1` signature and multi-secret; `account.updated` ordering guard; **`payments.stripe_account_id`**; Payment Element `stripeAccount`; **two webhook endpoints — Connect for v1 events, platform for `v2.core.account.*` thin events — and their secrets**; **a tenant `SELECT` by `stripe_connect_account_id`**; **a separate parse path for v2 thin events, which carry `related_object` and no `data.object`**; `application_fee.created`/`.refunded` subscribed; **set the launch revenue-share rate**, which shares this leg's deadline; Registry-initiated disconnect | 0, 1, 3a | 6-9 |
| 4 | `pricing_plan_versions` / `pricing_components` + immutability triggers; `pricing_plans` gains `provider_id` and `audience`, keeps `session_id`; **new `clone_schema` sqitch change with the skip list in every table-shaped loop**; normalize the two tenant table shapes, then migrate registry **and every tenant schema's** plans to v1; **repoint `PricingPlan->create` at the registry table**; `plan_scope`/`plan_type`/`pricing_configuration` kept nullable and dual-written by `PriceOps::Model->publish_version`; **the per-kind publish CHECK** (`stripe_price_id` required for `fixed`, NULL for `percentage`); **refuse to migrate a plan carrying sibling terms**; every column addition loops over **every tenant schema**, not just `registry` | 2 | 5-7 |
| 5 | Rewrite the `pricing-plan-creation` workflow and its templates onto the version/component vocabulary — **or delete it; decided after Leg 4, see below**. Either branch also closes the two entry points into it (`ProgramSetupOverview.pm:75`, `templates/pricing-plan-creation/complete.html.ep:51`) and the plan-creation call at `ReviewActivatePlan.pm:101-115` that passes **no `session_id`** | 4 | 1-4 |
| 6 | Publish projection: version → Stripe Product, component → Stripe Price **on the provider's account**; ids recorded; `published_at` written last; **backfill-publish every v1 migrated in Leg 4 whose provider has a Stripe account, skipping and counting the rest**; `Subscription.pm` stops building inline `price_data` | 3, 4 | 2-3 |
| 7 | `pricing_schedules` + **`CREATE EXTENSION btree_gist`** + the overlap exclusion constraint; migrate `pricing_relationships` + `platform_pricing_plan_id` (**both kept and dual-written — the table has a live reader until Leg 8**), writing a schedule row for **every** tenant; delete the dead modules and `DAO::BillingPeriod` | 4 | 2-3 |
| 8 | `Entitlement` + `Quote` + `Model->offered_versions`; rewire the charge; **`Schedule` creates direct-charge subscriptions with `application_fee_percent`** and an idempotency key; **subscription envelope dispatch**; omit-never-zero `application_fee_amount`; repoint `PricingPlanSelection` and `GenerateEvents`; delete `calculate_enrollment_total` and the `!$ENV{STRIPE_SECRET_KEY}` bypass; refuse-not-zero; **move the `stripe_connect_ready` gate ahead of the quote**, or an unconnected tenant 500s where it used to get a sentence; `customer.subscription.updated`/`.deleted` handlers, because `dashboard: full` lets a tenant cancel a Registry-created subscription; `proration_behavior: 'none'`; `RevenueShare` becomes a wrapper | 6, 7 | 5-7 |
| 9 | Quote columns on `payments` incl. `refund_application_fee` **and the quote's currency, which no caller has ever passed**; `Payment` fields and `save` column list extended; fee recorded; `DAO/AdminDashboard.pm:36` corrected; **add the Customer configuration to each tenant's `Account` and swap `customer` for `customer_account`** — a one-way door, since a v2 Account cannot drop a configuration, so this leg is the last chance to decide against it; **drop the deprecated columns, `tenants.stripe_customer_id`, the tenant-schema `pricing_plans`, and `pricing_relationships` + `billing_periods`**; check `sql/verify/stripe-subscription-integration.sql:9` | 8 | 3-4 |
| 10 | **Create `metering_events`**; `Metering`: record every monetizable event including zero-priced ones | 7 | 1 |
| 11 | Pillar 5 **for the model only**: `./registry pricing` CLI + CHECK constraints; retire hand-typed SQL seeds. The schedule and storefront change-classes are deferred — see "Out of scope" | 4, 5, 6 | 1-2 |
| 12 | Dispute resolution *surface*: admin page, embedded components, AccountSession; `Job::ReconcilePayments`; **widen the CSP at `Registry.pm:524,527`, which today allows only `js.stripe.com` and will block Connect's embedded components**. The `charge.dispute.*` handlers themselves are Leg 3 — Leg 12 is what a human sees | 0, 3, 9 | 2-3 |

**39 to 58 sessions** — 10 to 29M tokens, a spread wide enough that the token figure is
context rather than a budget. Leg 5's floor moves from 0 to 1: even the delete branch has to
close the two entry points that would otherwise 404 and decide what replaces
`ReviewActivatePlan`'s plan creation, so zero was never a legal answer to a fork whose cheap
branch is still a branch.

**The number has moved four times — 31-46, 33-49, 32-51, now 39-58 — and the direction is the
finding.** Each round of review has found work rather than savings, and the movement is
almost entirely in the legs that touch the charge path: Leg 3 went 4-6 to 6-9 on the second
webhook endpoint, the v2 thin-event parse path and the launch rate; Leg 3a went 2-3 to 3-4
because the API bump silently breaks five invoice handlers rather than none; Legs 0, 4 and 8
each picked up a session on work that was assumed rather than listed. Nothing has been
removed. An estimate that only ratchets up is an estimate that started as a guess about a
system nobody had finished reading, and the honest reading of 39-58 is that it will move
again — the useful question is whether the *shape* is stable, and after six rounds it is: the
same four legs hold the same share.

Legs 3a, 3, 4 and 8 are 19 to 27 of that, about half the milestone in four legs, and the
concentration is the
useful signal: they are the charge model, the model tables and the resolver, and each is
large because it touches code rather than because it adds a table. Leg 3 accumulated the
hardening items that stop being optional once the tenant holds the account; Leg 4 needs a new
`clone_schema` change, a shape normalization, a per-tenant column loop and a write cutover
rather than one migration; Leg 8 is where every read path moves at once.

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

**`pricing_relationships` is the third column in that pattern and an earlier draft dropped it
in Leg 7 anyway.** The table is only *written* by dead code, which is what "What gets deleted"
argues from, but it is still *read* by live code: `PricingPlanSelection.pm:10` uses
`DAO::PricingRelationship`, `:84` and `:139` call `->find` on it, and that step is `pricing`,
step 4 of the 7 in `workflows/tenant-signup.yml` — the menu a new tenant picks a plan from.
Leg 8 is what repoints it at `Entitlement`. So Leg 7 dropping the table opens a full leg in
which tenant signup dies at step 4, and it dies in the leg *after* the one whose migration
caused it, which is the worst possible place to debug it. The table follows the same rule as
the two columns: Leg 7 writes a `pricing_schedules` row for every relationship and leaves
`pricing_relationships` in place, Leg 8 moves the reader, Leg 9 drops the table. That drags
`billing_periods` to Leg 9 with it, since the FK at `sql/test-schema.sql:4431` is what forced
them into one migration; the dead *modules* still go in Leg 7, because deleting a writer
nothing calls breaks nothing.

**Leg 6 cannot publish for a tenant that has no Stripe account, and today that is every
tenant.** Publishing puts the Product and the Prices on *the provider's* account, so a
tenant's program plan needs `tenants.stripe_connect_account_id`. No row has one: no `acct_`
id appears anywhere in `sql/`, and the column is NULL throughout `sql/test-schema.sql`. Leg 6
backfill-publishes every v1 Leg 4 migrated, so run as written it either dies on the first
tenant plan or writes a `published_at` with no Stripe ids behind it — and the second outcome
is the dangerous one, because Leg 8 will then quote a version it cannot collect against.
Leg 6 backfills only for providers that have an account, leaves the rest as drafts, and
`log`s the count it skipped; a tenant's plans publish when that tenant connects, which is a
step of onboarding rather than a step of this migration. Registry's own platform plan is
unaffected — the platform account is the one account that exists.

**And Leg 8's refusal arrives upstream of the friendly message that exists to catch it.**
`WorkflowSteps/Payment.pm:131` already handles an unconnected tenant well: it returns
*"Online payment is not yet available for this organization"* and keeps the parent in the
workflow. But it only runs after a total has been computed, and the two calls that compute it
— `calculate_enrollment_total` at `:38` and `:68` — are both ahead of it. Leg 8 replaces
those calls with `Entitlement->quote`, whose entire contract is to refuse when nothing
resolves, so an unpublished plan on an unconnected tenant becomes an exception at `:38` and
the parent gets a 500 where they used to get a sentence. Leg 8 therefore moves the
`stripe_connect_ready` check ahead of the quote rather than after it. This is the general
shape of the leg: a resolver that refuses is correct, and every caller that was written
against one that returned nothing has to be re-read before it gains a refusal.

**Dual-writing needs a named owner, and it is `PriceOps::Model->publish_version`.** "Stays
dual-written" is not a property a column has; it is work some function does, and if no
function is named the window silently becomes a single-write window. The owner has to be
`publish_version` because Legs 4 and 5 between them rewrite every current writer off the old
vocabulary: `PricingPlanBasics.pm:49` and `ReviewActivatePlan.pm:102,171` carry `plan_scope`
through the authoring workflow that Leg 5 rewrites or deletes,
`UnifiedPricingEngine.pm:97` sets it on `create_pricing_plan` (`:130` is a *read* filter in
`get_available_plans_for_tenant`, not a third writer — an earlier draft counted it as one),
and `TenantPayment.pm:429` writes
`platform_pricing_plan_id` at tenant signup. `PricingPlan.pm:62`, the `//= 'customer'` default
inside `create`, belongs to **Leg 4** rather than Leg 5 — Leg 4 is what repoints `create` at
the registry table, so that is the leg that reads the method and the leg that must not silently
drop the default while it is there.

Once those writers are gone, nothing writes the
columns `RevenueShare.pm:61,117` still selects on — and it does not fall back, it dies with
*"This is a deployment bug"* (`:67-68`, `:123-124`). So from Leg 5 through Leg 9, `publish_version`
writes the legacy `pricing_plans` row alongside the version, mapping `audience` back to
`plan_scope`. Leg 9 deletes the second write and the columns in the same migration.

**The two windows do not open in the same leg, and an earlier draft opened both at 5.**
`plan_scope`'s window is Leg 5 to Leg 9, because Leg 5 is what removes its writers.
`platform_pricing_plan_id`'s cannot start before **Leg 7**, for the flat reason that
`pricing_schedules` does not exist until then: "the tenant-signup step writes both a schedule
row and the pointer" is not a thing that can be done in Leg 5 or Leg 6. Until Leg 7 the pointer
is not dual-written, it is simply *the* write, which is correct and needs no owner. Testing
already states the windows as 5-9 and 7-9; this is the sequencing catching up to it.

**Every one of these legs also assumes its migration ran, and production does not
guarantee that.** `docker-entrypoint.sh:20-24` runs `sqitch deploy`, and on failure prints
`"Warning: Database schema deployment failed"` and starts the app anyway — new code
against an old schema, which for a pricing leg means the resolver querying a table that
does not exist on a live checkout. The worker is worse: `render.yaml:75` defines it with no
migration step at all, so it boots against whatever schema the web service happened to
leave behind, and the worker is what runs the payment jobs. This is not caused by this
milestone, but this milestone is what makes it expensive — fourteen legs, nine or more sqitch changes,
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
that test is part of the leg, not a follow-up. Testing says the same thing and adds the part
that makes it actionable: there is no harness for it — `t/database/migration-verification.t:46-49`
is a `pass()` that skips rollback entirely — so Leg 0 writes one. It is repeated here because
the sequencing is where it will be skipped.

*A backup taken before the leg, not after the problem.* `README.md:130` still has the backup
item unchecked. A pricing migration that mangles rows is not recoverable from a revert script
alone, because the revert restores the schema and not the data.

*A named half-deployed state per leg.* Legs 3, 4, 6, 7, 8 and 9 cannot safely be left
half-done. An earlier draft listed only the four with migrations, which is the wrong filter:
what makes a state unsafe is *money moving through a path that is half-cut over*, and a code
leg can do that without touching `sql/deploy/` at all. Leg 3 is the worst of them — it changes
the charge from destination to direct, and a deploy that lands the new `_connect_params` but
not the new webhook secrets takes real charges Registry never hears about. Leg 8 is the other:
it moves every read path onto the resolver, so half of it deployed is half the enrollments
quoting and half refusing. Leg 6's publish backfill remains the clearest case because it is
non-transactional with no retry, leaving some versions with Stripe ids and some without, and
the ones without are unsellable. Every leg states what "stopped halfway" looks like and
whether it is safe to sit there overnight. Where the answer is no, the work is either one
transaction or idempotent enough to re-run from the start; Leg 6's backfill becomes the
latter.

The three Render services — web, worker and cron at `render.yaml:39,75,96` — all carry
`autoDeploy: true` (`:69,94,110`) and only the web service runs migrations, so a merge deploys
all three independently against a schema one of them just changed. There is no staging environment and no feature flag anywhere in this
design. That is survivable for legs that only add tables; it is the reason Legs 3, 8 and 9 —
which change the charge model, then move every read path, then drop the columns behind it —
should be the three legs that get a manual deploy rather than an automatic one.

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

**Leg 2 goes early for a data reason, and an earlier draft gave a code reason that runs
backwards.** That draft argued the all-zeros UUID appears in exactly five places in `lib/`,
every one of them in code this milestone already deletes or rewrites — `PricingRelationship.pm:140`
and `UnifiedPricingEngine.pm:26` die in Leg 7, `PricingPlanBasics.pm:70` and
`RequirementsRules.pm:186` are inside the authoring workflow Leg 5 rewrites, and
`PricingPlanSelection.pm:14` (the `PLATFORM_UUID` constant) is in the tenant-signup workflow
Leg 8 repoints — and concluded that collapsing early corrects them "once, as part of a rewrite
that was happening anyway." The premise is right and the conclusion inverts it. Leg 2 sits at
position 3; Legs 5, 7 and 8 are four to six legs later. Editing those five sites in Leg 2 and
then deleting them in Leg 5, 7 and 8 is touching them *twice*. If the code argument were the
whole argument, Leg 2 should go **last**, after its own sites have deleted themselves.

The argument that actually holds is about rows, not lines. Leg 4 migrates every plan to a
`provider_id`, and if `registry-platform` still exists at that point every one of them gets
all-zeros and Leg 7 migrates them a second time — a data migration repeated over a table the
whole milestone depends on, which is a materially worse thing to repeat than five constant
edits. The SQL side reinforces it: `unified-pricing-infrastructure.sql` alone holds seven
occurrences, and those are deployed migrations that are never edited, only superseded, so the
identity has to be correct in the data before Leg 4 reads it. **Leg 2 is not free; it is cheap
relative to migrating `pricing_plans` twice.**

**And the tests are where "cheap" stops being cheap.**
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

**Every leg that adds a migration adds one `prove` will not see.** Tests
build their database from a pre-generated dump: `Test::Registry::DB` loads
`sql/test-schema.sql` when it exists and only falls back to a sqitch deploy when it does
not (`t/lib/Test/Registry/DB.pm:13-16,63-68`). `make test` regenerates the dump because the
Makefile makes it a prerequisite (`Makefile:6,9-11`), but the `prove` invocation above —
the one this project actually types — does not. So a schema leg whose tests pass locally
proves only that the *old* schema still works. Every leg that touches `sql/deploy/` runs
`make test-schema` and commits the regenerated dump in the same commit as the migration;
a leg where `sql/test-schema.sql` is unchanged and `sql/deploy/` is not has not been
tested.

**Earlier drafts said "seven of the fourteen legs add a migration" and it was an undercount.** Counting the
table: Legs 0, 2, 3, 4, 6, 7, 9 and 10 all change `sql/deploy/`, and Legs 4 and 7 need more
than one change each — Leg 4 alone is the version/component tables, the `pricing_plans`
columns, the tenant-schema normalization and a fresh `clone_schema`. **Eight of the fourteen
legs add at least one migration, and the milestone is nine or more sqitch changes.** The
number matters only because the per-migration obligations below are per-*change*, not
per-leg, and a leg that quietly contains three of them costs three times what the sentence
suggests.

**Each change also ships a verify script, and this is enforced already.** `sqitch.conf` sets
`[deploy] verify = true`, and `t/database/migration-verification.t:18-44` deploys the whole
plan to an ephemeral Postgres and runs `sqitch verify` over every change. All 64 deploys have
a matching verify today. So a leg that adds a migration and no verify does not merely skip a
nicety — it turns that test red, in a file whose name gives no hint that the pricing work
broke it. Write the verify with the deploy.

**Each change also gets a revert test, and there is no harness for one.** The rollback
subtest in that same file is `pass("Skipping rollback tests - focus on deploy and verify")`
(`t/database/migration-verification.t:46-49`) — a green assertion that asserts nothing, the
same shape as #296. So "every migration ships a tested revert" is not an instruction that can
be followed by adding a script; the first leg with a migration writes the harness: deploy to
the change, revert one, deploy again, compare the schema. Leg 0 has a migration and is early,
so it owns it. Until that exists, "tested revert" means a human ran `sqitch revert` once, and
that is worth saying out loud rather than implying a suite covers it.

**Backfills must be re-runnable, and one already is not.** Legs 4, 6 and 7 all backfill, and
the half-deployed-state rule below says a partial run has to be safe to re-run from the
start. The precedent is discouraging: `sql/deploy/pricing-plans-amount-cents.sql:50-56` raises
an exception on any row it does not recognize, so on a database where a previous attempt
converted some rows the second run aborts the whole deploy. Each backfill in this milestone
states its idempotency key — for Leg 4 the presence of a v1 for that plan, for Leg 6 a
non-null `stripe_price_id`, for Leg 7 an existing schedule row for that (provider, consumer) —
and skips rather than raises on a row that already has it.

**Where a revert is lossy it says so in the script.** `sql/revert/pricing-plans-amount-cents.sql:9-14`
is the model: it states in a comment that the original decimal values cannot be recovered from
the integers, and reverts the schema anyway. `sql/revert/enhanced-pricing-model.sql:38-41` is
the counterexample and is cited here as one — it silently runs
`DELETE … WHERE ctid NOT IN (SELECT MIN(ctid) … GROUP BY session_id)`, destroying rows on the
way back with no comment and no ABOUTME. A revert that deletes data without saying so is worse
than one that refuses. Say which of the two shapes each revert is, in the script, at the top.

**And one test per dual-write window.** The windows are the riskiest thing in the
sequencing — Leg 5 through Leg 9 for `plan_scope`, Leg 7 through Leg 9 for
`platform_pricing_plan_id` — and the failure mode is silent: the second write is dropped,
the old reader finds nothing, and `RevenueShare` dies at charge time with a message about
a deployment bug. The test publishes a version through `PriceOps::Model` and asserts the
legacy row exists with the mapped `plan_scope`, so the window closing early fails in the
suite rather than at a parent's checkout.

One invariant test per pillar. **Each names the leg that owns it**, because a list of five
tests at the end of a testing section is a list nobody is accountable for, and three of the
five cannot even run when the milestone starts — there is no version table to fail to update
until Leg 4 and no resolver to interrogate until Leg 8. The owning leg is the first one in
which the test can pass, and it ships in that leg's commit:

1. **Leg 4** — a published plan version cannot be updated, and cannot be deleted: `UPDATE`
   raises, `DELETE` raises, and `TRUNCATE` is revoked because it skips row triggers.
2. **Leg 8** — a quote resolved at time T returns the version in effect at T after a later
   version is published. It needs the schedule (Leg 7) *and* the resolver, so it cannot land
   with the exclusion constraint that makes it true.
3. **Leg 10** — a zero-priced enrollment on a Free-tier tenant still writes a `metering_events` row.
4. **Leg 8** — no production code path reads a plan by name; the resolver rejects a version it cannot price.
5. **Leg 11** — a plan authored via CLI and one authored by the workflow are identical on the authored
   columns — not byte-identical, which no two rows with distinct `id`s and `created_at`s
   can be. The comparison names the columns: `provider_id`, `audience`, and every
   component's kind, cadence, currency and amount. A rateless percentage plan is rejected
   at authoring. This invariant assumes the workflow survives Leg 5; if Leg 5 deletes it,
   there is no second author and this becomes a CLI-only assertion — the rateless rejection
   and the constraint coverage, without the comparison.

Plus one translator invariant (**Leg 6**): publishing a version twice is idempotent and creates exactly
one Stripe Product, and no code path outside `PriceOps::Model` sends `price_data` — a grep
assertion, because that is how the current inline-Price defect got in and how it would
come back.

Plus one tenancy invariant (**Leg 4**, with the `clone_schema` change, and extended in Leg 7 as
tables are added), because `clone_schema` is silent when it is wrong: onboard a
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
- **Two of Pillar 5's three change-classes.** Pillar 5 covers changes to the pricing *model*,
  to a *customer's plan or billing*, and to *which plans display on a pricing page* — all
  three through tools working against the single source of truth. Leg 11 delivers the first:
  `./registry pricing` plus the CHECK constraints that make a bad plan unrepresentable rather
  than merely unwritten. The other two ship as reads and writes with no tool in front of them.
  Moving a tenant between plans means writing a `pricing_schedules` row, and after Leg 7 the
  only ways to do that are the signup workflow and hand-typed SQL — the same out-of-band
  adjustment `suspend-rateless-tenant-plans.sql` is cited above as the symptom of. Which plans
  display is `offered_versions` reading `audience`, with no flag anyone can flip to
  retire a plan from the menu without unpublishing it. Both are cheap subcommands on the
  binary Leg 11 already builds, and both are deliberately not in Leg 11's estimate. **The
  milestone should be described as satisfying Pillar 5 for the model and deferring it for the
  schedule and the storefront**, because the version that says "Pillar 5: done" is the version
  that gets a schedule edited by `psql` a year from now.
- **Admin UI for authoring *platform* plans.** A UI when a human who is not perigrin needs to
  author a platform plan; until then the CLI is the author. An earlier draft dropped the word "platform" and so read as though
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
    `provider_id` — tenant-scoped program plans (three of them, at `unified-pricing-infrastructure.sql:106,119,132`,
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
    after (24) added Leg 3a, **32 to 51** after (29) and (30), and **39 to 58** after (32)
    through (36) — four revisions, all upward except the one Leg 5 fork, which is itself now
    corrected from a floor of 0 to a floor of 1. Sequencing says why the direction matters
    more than the number.
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
31. **Two more, and both are about zero — which is the argument for (30) rather than a
    footnote to it.** They came from the same review round as (30)'s five and were left out
    of that list. Neither is a PriceOps defect, both are money defects, and under the old bar
    both would have been filed and forgotten. An early-bird plan makes its children
    *free* rather than unpriced, because an epoch integer is compared against a
    hyphen-stripped date string and the price comes back `undef` into a `defined` check that
    skips. And the platform's own share is *zero* rather than the advertised 2.5%, because
    `seed-free-platform-plan.sql:24` says `0.00` and `platform_default_fraction` faithfully
    returns it. Both are documented above with their line numbers. Neither is expensive: the
    first is a refusal guard in Leg 0 and a deletion in Leg 8, the second is a decision — which
    (33) below moves from Leg 11 to Leg 3 — and the milestone's own acceptance criterion already fails until the second is
    made, which is the criterion doing its job rather than a gap in it. "Aligned with PriceOps
    and charging nothing" was a state the old bar would have accepted.
32. **A percentage component has no Stripe Price, and the publish gate said every component
    needed one.** Written as stated, Leg 6 could not publish Registry's own 2% revenue-share
    plan and Leg 8 could not quote it — the milestone's central plan, unpublishable by its own
    rule. The gate becomes per-kind: `stripe_price_id` required for `fixed`, and required to be
    NULL for `percentage`, because a percentage of the tenant's revenue is
    `application_fee_percent` on a subscription, which is a parameter and not an object.
    (12)'s "the pure percentage case ships" was right and (12) did not follow the consequence
    into the CHECK.
33. **The launch rate moves from Leg 11 to Leg 3.** (31) put it in Leg 11 "with the CLI that
    makes changing it something other than hand-typed SQL." Leg 11 is position 13; Decision 3
    requires Leg 3 to merge before the first tenant onboards, at position 5. Nothing enforces
    an ordering between them, so every tenant onboarded in between is charged nothing for
    eight legs — on a charge path that is otherwise working, which is the failure mode that
    looks exactly like success. Setting the rate is a one-line data migration and goes with
    the deadline it shares; Leg 11 keeps the tooling, which was always the part that was work.
34. **Three legs stranded a live caller, and all three are now sequenced against it.** They
    are the same mistake three times — a leg that moves a *writer* or a *table* one or more
    legs ahead of the leg that moves the *reader*. Leg 4 repoints `PricingPlan->create` at the
    registry table while `get_pricing_plans` still reads the tenant one, enrolling children
    free for four legs. Leg 6 backfill-publishes for tenants that have no Stripe account to
    publish to. Leg 7 drops `pricing_relationships` while `PricingPlanSelection` still reads it
    as step 4 of tenant signup. The rule the spec had for columns — supersede early, drop late —
    is now applied to tables and to write cutovers as well, and each site says so where it
    happens rather than in a general principle nobody re-reads.
35. **Two migrations as written would not deploy.** The `pricing_schedules` exclusion
    constraint needs `CREATE EXTENSION btree_gist` (the operator class for `uuid` `=` inside a
    GiST index is not in core) and cannot call `uuid_nil()` (also not core) — a literal
    all-zeros uuid replaces it. And every column addition in Legs 3, 4 and 9 must loop over
    each tenant schema, following `sql/deploy/payments-amount-cents.sql:30-54`; a bare
    `ALTER TABLE registry.…` leaves every tenant's copy without the column, and
    `sql/test-schema.sql` contains no tenant schemas, so nothing in the suite would have
    caught it. Both were found by reading the deploy scripts rather than the design.
36. **The milestone lands Pillar 4's constraint and Pillar 5's first change-class, and the
    spec now says so.** `Entitlement` answers "what does this cost," not "may this customer do
    this" — there are no gated features to check, and building a flag layer with nothing behind
    it is the speculative generality this design refuses elsewhere. `./registry pricing`
    covers changes to the *model*; changes to a customer's schedule and to what displays on the
    storefront remain hand-written. Both are correct scope and neither was recorded as scope.
    A milestone described as "aligned to the five pillars" that satisfies three and a half of
    them is the kind of claim that gets repeated until someone believes it.

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
  by this design, but nine or more migrations across fourteen legs make it much likelier to bite, and
  the failure mode is new pricing code querying a table that is not there. Its own issue,
  fixed before the first leg deploys.
- **Multi-currency plans have a settlement side this design does not model.** Decision 4
  allows a plan to mix currencies across components, and the resolver treats currency as a
  property of the component. Stripe's rule is about the *account*: funds always settle in the
  country of the connected account, so a US-registered tenant selling a CAD component is
  collecting CAD and settling USD, with Stripe's conversion and its spread in between. Nothing
  in the quote records which side of that a number is on. That is acceptable while every
  tenant and every component is USD — which is today — and it becomes a correctness question
  the moment the first CAD component is authored, because the `application_fee_amount`
  Registry computes is in the charge currency and the amount Registry receives is not. Name
  the exposure before Leg 8 rather than after the first cross-border invoice.
- **Onboarding does not yet exist as code, and Leg 6 now depends on it.** Leg 6 publishes only
  for providers with a Stripe account, so a tenant's plans stay drafts until they connect. No
  module in `lib/` creates a connected account — `docs/operations/sacp-stripe-connect-onboarding.md`
  is a human procedure — so "publish on connect" has no hook to hang on. Either onboarding
  gains one in Leg 3, or publishing stays a manual step per tenant and that is written into
  the runbook. Decide it in Leg 3; do not let Leg 6 discover it.
