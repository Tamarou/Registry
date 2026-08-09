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
| 1. Model definition | `pricing_plan_versions` + `pricing_components` | Product + Price — **a Price's `unit_amount`, `currency` and `recurring` are immutable**; you create a new one rather than edit |
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
criterion is made executable as `t/stripe-live/author-a-new-plan.t`, gated on five things a
test *can* check:

1. The test shells out to `./registry pricing` with a plan shape no current code path
   assembles — a monthly membership on a connected account — and the command exits zero.
2. It enrolls a family against the resulting plan through the ordinary enrollment path and
   asserts a Stripe subscription exists **on the tenant's account** with the expected amount,
   currency and interval, **carrying `application_fee_percent`**, and that one invoice has
   settled with an `application_fee_amount` **equal to the rate times the invoice total, to
   the cent** — not merely non-zero. A wrong-but-positive fee is exactly the `percentage: 1`
   ambiguity between 100% and a 1% typo, sailing through an assertion written to catch it.
   **The field this reads is not on the Invoice after Leg 3a.** `2025-03-31.basil` "removed
   the `application_fee_amount` and `transfer_data` fields from the `Invoice` object. For
   payments made on Stripe, these fields are now accessible through the underlying
   PaymentIntent by expanding `payments.data.payment.payment_intent`." So the assertion reads
   `invoice.payments.data[0].payment.payment_intent.application_fee_amount` behind that
   expand, or the `ApplicationFee` object directly. An earlier draft framed this as a test
   "written against acacia" that "returns `undef` the day Leg 3a lands"; Leg 13 is position 16
   and Leg 3a is position 4, so this test never sees acacia and there is no transition for it
   to survive — it is written against the pinned version from its first line. What survives the
   correction is the trap it was pointing at: the reflex repair for an `undef` here is to
   weaken the assertion to non-zero, which is the failure this gate exists to prevent. The
   write side is unaffected: `application_fee_amount` remains a valid create parameter.
3. **It makes the same assertion on the one-time path**, which point 2 does not reach. A
   subscription is created by `PriceOps::Schedule`; every enrollment Registry takes today
   goes through `DAO::Payment` and a PaymentIntent, and those are different code with a
   different fee parameter. So the test also enrolls against a `fixed`/`one_time` component
   and asserts a PaymentIntent on the tenant's account carrying the expected
   `application_fee_amount`. Without this the milestone can pass its own gate with ordinary
   checkout broken — and the three silent `return ()` guards in `_connect_params`
   (`Payment.pm:78,84,86`, on a missing-or-`registry` tenant slug, a missing tenant row and a
   missing `stripe_connect_account_id`) are precisely how it would break: each one produces a
   working charge that pays Registry nothing. There is no fourth guard on a zero fraction —
   that case produces `application_fee_amount => 0`, which is the omit-never-zero violation
   below rather than a silent skip.
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

**Point 2 is a race, the opt-out Stripe sells in the same paragraph does not reach us, and
an earlier draft of this document said it did.** In full: *"Application fees for direct
charges are created asynchronously by default. If you expand the `application_fee` object
**in a charge creation request**, the application fee is created synchronously as part of
that request. Only expand the `application_fee` object if you must, because it increases the
latency of the request. To receive notifications of asynchronously created `ApplicationFee`
objects, listen for the `application_fee.created` webhook event."* That draft read the middle
sentence as dissolving the race and had the gate pass `expand[]=application_fee` on the create
call — "no poll, no wait, no flake."

The qualifier is the whole clause: it is a **charge** creation request. Registry never issues
one. `Payment.pm` creates PaymentIntents, and a subscription's fee arrives on a charge Stripe
creates itself when it finalizes an invoice. Neither is a request the test can hang an expand
on, so the synchronous path is not available to this codebase at all and the fee genuinely
arrives after the object that carries it. **`application_fee.created` is load-bearing after
all**, and so is the wait the draft deleted: the gate reads the fee from the
`ApplicationFee` object, arriving either by that event or by a bounded poll of
`GET /v1/application_fees?charge=…`.

That restores a dependency the draft had removed, and the dependency has an unresolved edge:
**the reference does not settle which endpoint receives the event.** An `ApplicationFee` is a
platform-owned object created against a charge on a connected account; `connect/webhooks`'s
scope table does not list the event, and the event-types reference gives only "Occurs
whenever an application fee is created on a charge." Leg 3 subscribes on the Connect
endpoint and **verifies delivery in the Leg 3a test-mode spike rather than assuming it** —
which is now a gate question rather than only a reconciliation one, and is listed with the
spike's other questions below. A bounded poll is the fallback if delivery lands somewhere
unexpected; "a gate that flakes gets disabled" is a real risk and the poll is written with a
deadline and a loud failure rather than a retry loop.

The test asserts **`livemode: false`** on every object it touches, because the one failure
this repository must never have is a green acceptance run against real money.

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
an earlier draft said it could.** Leg 11 sits at position 14 of 16; Decision 3 says Leg 3
must merge *before the first tenant onboards*, at position 5. Nothing in the code enforces
an ordering between them — `revenue_share_fraction_for_tenant` (`RevenueShare.pm:25-72`)
reads `pricing_configuration->>'percentage'` fresh on every call with no caching, so the
0.00 simply keeps being returned. Follow both instructions literally and every tenant
onboarded after Leg 3 is charged nothing for nine legs, on a charge path that is otherwise
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
no code. Point 4's grep is the closest mechanical proxy and it is a proxy — and it measures only
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
| `PriceOps::Entitlement` | 4 | The sole *price* read path: the one place a caller learns what something costs. Resolves Schedule → Model, returns a Quote. Never touches Stripe. Callers never name a plan. It does not answer "what may this consumer buy" — that is a list, and it is `Model->offered_versions`; see "Which plans are offered, and to whom." "Sole read path" unqualified was wrong. |
| — | 5 | Not a module: `./registry pricing` CLI plus CHECK constraints that make an invalid plan unauthorable. `Registry::Command::*` establishes the shape, though not uniformly — `schema.pm:24`, `template.pm:20` and `workflow.pm:128` take `run($cmd, $schema, @args)` while `tenant.pm:20` omits the schema and `workflow_job.pm:37` is a plain `sub`. Follow the three-of-five majority; the schema argument is the provider identity. |

**The existing authoring workflow is in scope and is the larger half of Pillar 1.** Dropping
`plan_scope`, `plan_type` and `pricing_configuration` invalidates the five step classes of
`workflows/pricing-plan-creation.yaml:13,18,23,28,33` — `PricingPlanBasics.pm:18,20,47,49`,
`PricingModel.pm:17`, `ResourceAllocation.pm:133`, `RequirementsRules.pm:145`,
`ReviewActivatePlan.pm:102-105,169-174` — **862 lines of step classes plus 1,412 lines of
`templates/pricing-plan-creation/`**, and the `pricing_plans_plan_scope_check` constraint.
An earlier draft named `pricing_model_type` in that list instead of `pricing_configuration`,
and no leg drops `pricing_model_type` — Leg 9b's drop list is
`plan_scope`/`plan_type`/`pricing_configuration`. The column outlives the milestone on the
tenant-schema `pricing_plans` table that Leg 9b also drops, so it goes with the table rather
than on its own; naming it as a column drop sent an implementer looking for a migration that
does not exist. An
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

**"Drop" and "rename" in this section mean *by the end of the milestone*, not in the leg
that introduces the replacement.** `plan_scope`, `plan_type` and `pricing_configuration` are
all kept nullable through Leg 9b — the leg table is the authority on when a column actually
goes. The *dual-write* window is narrower than the retention window and opens at **Leg 5**,
not Leg 4: through Leg 4 the legacy writers are still the only writers, so there is nothing to
duplicate; Leg 5 is what removes them and therefore what makes
`PriceOps::Model->publish_version`'s second write load-bearing. See "The two windows do not
open in the same leg." This paragraph is repeated because the identical trap has
already been walked into once with `tenants.platform_pricing_plan_id`: a Leg 4 author who
reads only the data model writes a rename and breaks `RevenueShare.pm:58-64`, which reads
`plan_scope`, for four legs.

**`plan_scope` is not implied by the provider, and an earlier draft dropped it saying it
was.** Registry offers two disjoint sets of plans and both have `provider_id` = registry:
the signup menu a tenant chooses from (three of them, at `unified-pricing-infrastructure.sql:106,119,132`,
`plan_scope='tenant'`, read by `PricingPlanSelection.pm:93,147`) and the revenue-share
plans the platform applies to a tenant (`seed-free-platform-plan.sql:18`,
`plan_scope='platform'`, read by `RevenueShare.pm:58-64,114-120`). Same provider, two menus,
distinguished only by the column. Dropping it with nothing in its place loses the signup
page. It is renamed rather than deleted: `audience` — who the plan is *offered to* — which
is a different question from who provides it and deserves its own column.

**There are three values, not two, and the third is the default.**
`pricing_plans_plan_scope_check` (`sql/test-schema.sql:1216`) allows `customer`, `tenant` and
`platform`, and the column defaults to `'customer'` (`:1203`), which `PricingPlan.pm:62` also
supplies as `//= 'customer'`. `customer` is the ordinary case — a tenant's program plan
offered to a family — and it is the value every plan created through the authoring workflow
gets. This document has discussed `tenant` and `platform` at length and never named `customer`
once, which would leave Leg 4's rename mapping two of three values and defaulting the rest by
accident. `audience` carries all three, with the same default.

**`pricing_plan_versions`** — the immutable envelope. `plan_id`, `version`, `requirements`,
`published_at`, `stripe_product_id`. Immutability enforced by a `BEFORE UPDATE`
trigger rejecting changes to a published version, not by convention — and reinforced
downstream, since a Stripe Price's `unit_amount`, `currency` and `recurring` are immutable by
Stripe's own rules. **That reinforcement has a hole exactly where the multi-currency decision
below leans on it:** `currency_options` is an updatable parameter on `POST
/v1/prices/{price}`, alongside `active`, `metadata`, `nickname`, `lookup_key` and
`tax_behavior`. A second-currency amount can therefore be edited in place, out from under a
published version, with no new Price object. Registry's own versioning has to cover that
field; Stripe will not.

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
  currencies is a Stripe multi-currency Price (`currency_options`), not extra components —
  with the caveat above that `currency_options` is the one Price field Stripe lets you edit,
  so the version has to own it. Stripe also declines to settle the currency rule for the fee
  itself: *"The currency of `application_fee_amount` depends upon a few multiple currency
  factors."* A second currency is therefore a decision this milestone defers, not one it
  designs against a rule it does not have.
- `stripe_price_id` — filled in at publish. The component is the unit that maps one-to-one
  onto a Stripe Price, which is why the split lives here rather than on the version.

**`applies_to` is deferred to Leg 10 rather than added in Leg 4, because it has no
vocabulary and the name is already taken.** An earlier draft gave the component an
`applies_to` meaning "the metering event type this prices against" and then made it
load-bearing in resolution step 4 ("emit one line per component whose `applies_to` matches").
Matches what? The quote signature is `{ provider, consumer, product, at, quantity }` and
carries no event type. Worse, `applies_to` is an **existing** key with a **different**
meaning: `PricingModel.pm:97,121` writes it as `customer_payments` / `program_revenue`, and
`PricingRelationships.pm:239,272,293,308` and `UnifiedPricingEngine.pm:171,198,216` read it as
*which usage base this percentage multiplies*. Reusing the identifier for a metering join,
with no enumeration, leaves Leg 4 unable to pick the column's type or CHECK, Leg 8 unable to
write step 4, and Leg 10's `metering_events.event_type` agreeing with nothing. The dependency
is also backwards: the resolver (Leg 8) would precede the metering table (Leg 10) that gives
the column its values. So the column arrives in **Leg 10**, with the event vocabulary, and
resolution step 4 until then emits one line per component of the resolved version.

**And it stays that way: step 4 never filters on `applies_to` in this milestone.** An earlier
draft deferred the column but kept "make resolution step 4 filter on it" in the Leg 10 row,
which left the question above — *matches what?* — printed in the document and answered
nowhere. Supplying the vocabulary gives the filter a right-hand domain; nothing gives it a
left-hand value, because the quote signature at
`Registry::PriceOps::Entitlement->quote($db, { provider, consumer, product, at, quantity })`
is never amended. Writing the filter the obvious way is worse than leaving it out: Leg 10 is
position 14 of 17, after Legs 3, 8 and 9a have put the resolver on the live charge path, and
every component authored in Legs 4 through 9 predates the column and is therefore NULL. A
`WHERE applies_to = <event>` matches zero rows, every quote emits zero line items, and step
5's "refuse when nothing resolves" does not fire because a *version* did resolve — which is
the free-enrollment defect this design exists to close, reintroduced in the leg after the one
that closed it. So `applies_to` is a metering-side label: it records which event type a
component would price against, `metering_events.event_type` agrees with it, and nothing in
the charge path reads it. Usage-based billing is the change that would make step 4 filter,
and it is out of scope — named in "Out of scope" rather than half-built here.

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

**A hybrid already has a named consumer, and it is on the signup menu right now.**
"Registry Plus - $100/month + 1%" is seeded at `unified-pricing-infrastructure.sql:133` — the
name on `:133`, the `pricing_configuration` JSON on `:138` —
with `pricing_model_type = 'hybrid'` and `{"monthly_base": 100.00, "percentage": 0.01}`, and
its `pricing_relationships` row is **`active`** (`sql/test-schema.sql:2388,2408`).
`suspend-rateless-tenant-plans.sql:21-33` suspends only plans with no resolvable rate, so
Registry Standard went and Plus survived — deliberately, because Plus *has* a percentage.
`PricingPlanSelection.pm:75-160` builds the menu from exactly those active platform
relationships, so the first tenant to sign up after Leg 3 can pick it, and it works: $100/mo
via `TenantPayment.pm:145` → `Subscription.pm:125`, 1% via `pricing_configuration->>'percentage'`.

Then Leg 4 migrates it to a v1 carrying two components, the publish CHECK above refuses it in
Leg 6, and in Leg 8 `revenue_share_fraction_for_tenant` — by then a wrapper over the quote —
finds nothing published and refuses on **every enrollment in that tenant's schema**. They can
take no money until someone hand-edits them onto another plan, which is precisely the
out-of-band adjustment Pillar 5 exists to eliminate. The other resolution is worse: migrate
it as `percentage` only and silently stop billing the $100/mo.

**So Plus is retired from the menu in Leg 1**, the same way Standard was — one `UPDATE
pricing_relationships SET status = 'suspended'` — unless perigrin would rather name it as the
hybrid's consumer and pull the `invoice.created` handler into scope. It is a deletion with no
dependencies, and every day it stays active is a day the funnel offers a plan the model is
about to stop being able to express. The "no named consumer" line under "Out of scope" is
corrected accordingly: hybrid has one, and this is how it stops having one.

**"Retire" here means suspend the offer, not migrate a subscriber, and that is a checked fact
rather than an assumption.** A read-only query against production on 2026-08-09 returns zero
tenants with `platform_pricing_plan_id` pointing at Plus; both tenants that exist point at
"Registry Revenue Share - 2%". So the `UPDATE` is menu-only: nothing is being billed under
Plus, nothing has to be moved off it, and Leg 1 needs no migration path for an existing
subscriber. **Re-run that count in the Leg 1 branch before merging** — the fact is true today
and the funnel is open, so a tenant could sign up for Plus between now and then, and if one
has, Leg 1 stops being a one-line `UPDATE` and becomes a conversation about somebody's bill.

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
dual-written from Leg 7 until Leg 9b, for the reason given under "Legs 4 and 7 do not drop the
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
**`CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public`** and the coalesce sentinel stays a
literal — one dependency instead of two.

**The `SCHEMA public` is not decoration, and getting it wrong is a production-only outage.**
`CREATE EXTENSION` with no `SCHEMA` clause installs into the first entry of `search_path`, and
45 of the 64 scripts in `sql/deploy/` open with `SET search_path TO registry, public`. Under
that majority template the extension's ~212 functions get `pronamespace = registry`, and
`clone_schema`'s functions loop — `SELECT proname, oid FROM pg_proc WHERE pronamespace =
src_oid` at `fix-clone-schema-identifier-quoting.sql:399-408`, with no extension-membership
filter — then runs `pg_get_functiondef` and `EXECUTE` on every one of them for each new tenant.
They are `LANGUAGE C`, and only a superuser may declare a C function. `Test::PostgreSQL` runs
as `postgres`, so CI creates all 212 copies happily and stays green while quietly littering
every tenant schema. Production does not: the Render role is `registry_db_user` with
`rolsuper = false` (confirmed read-only against `dpg-ckq1i8o5vl2c73d61070-a`), so the loop
raises `permission denied for language c`, `clone_schema` aborts, and `Tenant->create`'s
transaction rolls back. Tenant onboarding stops, in production only, on a milestone whose
purpose is taking money from new tenants. `GRANT USAGE ON LANGUAGE c` cannot rescue it — the
language is untrusted and the grant is refused. The extension's own `trusted = true` covers
`CREATE EXTENSION` itself and not re-declaring its functions.

The hazard is conditional on which template Leg 7's author copies: the nine pricing-family
migrations set no `search_path` and fully-qualify `registry.` instead, and under that style the
extension lands in `public` by accident. Naming the schema costs one word and removes the
coin flip. Default operator-class lookup ignores `search_path`, so `public` costs the
constraint nothing. This is the same class as the two migrations under (35) that would not have
deployed as written — an authoring trap, caught before it is authored.

The failure matters because `docker-entrypoint.sh:20-24` warns on
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
`percentage` becomes a component's `rate`, the money becomes a `fixed`/`recurring`
component's `amount_cents`, and `refund_application_fee` becomes nothing. So
`pricing_plan_versions` carries **`refund_application_fee boolean NOT NULL DEFAULT true`**
— it is a property of the terms sold, not of a component, which is why it sits on the version
beside `requirements` rather than being repeated per row. The Quote carries it through and
Leg 9a stamps it.

**Say which column the money comes from, because the obvious reading of that sentence is a
hundredfold undercharge.** An earlier draft wrote "`monthly_amount` becomes a `fixed`
component's `amount_cents`", which names a JSON key holding **dollars** as the source for a
column holding **cents**: `sql/deploy/unified-pricing-infrastructure.sql:125` seeds Registry
Standard with `{"monthly_amount": 200.00}` while the same row's `amount_cents` is `20000`
(`sql/test-schema.sql:2387`). Followed literally, Leg 4 makes Standard a $2.00/month
component, Leg 6 publishes that as its Stripe Price, and Leg 8's Schedule bills it. The key
name is actively booby-trapped, because in the *code* it means cents — `Subscription.pm:109`
is `monthly_amount => 20000, # $200.00 in cents` and `TenantPayment.pm:145` is
`monthly_amount => $selected_plan->{amount_cents}` — so the same identifier carries different
units on either side of the JSON boundary, and this document itself uses the cents sense
2,400 lines later.

**`pricing_plans.amount_cents` is the sole money source for a migrated component**, for
platform plans and customer-scoped session plans alike. `sql/deploy/pricing-plans-amount-cents.sql:27-35`
dropped the `amount` column, so cents is the only money column left. The dollar-valued
`pricing_configuration` keys get no successor; the migration asserts
`ROUND((pricing_configuration->>'monthly_amount')::numeric * 100) = amount_cents` where the
key is present and refuses the row on mismatch. The correction matters most for the rows
nobody was thinking about: customer-scoped session plans — the enrollment money path — carry
the default `'{}'` configuration (`unified-pricing-infrastructure.sql:28`) and their price is
written to `amount_cents` only (`ReviewActivatePlan.pm:107`), so under the old sentence they
had no money source at all and Leg 4 was unexecutable for the majority of its rows. The
platform half is the quieter one: `suspend-rateless-tenant-plans.sql:21-33` suspended
Standard's relationship and Leg 1 retires Plus, so a 200-cent Price would sit unsold until
someone un-suspended it. A trap rather than a charge, which is worse for finding it.

**And the resolver cannot read a stamp with the signature it has.**
`refund_application_fee_for_tenant($db, $tenant_slug)` (`RevenueShare.pm:87`) takes no
payment and therefore cannot reach the row the policy was stamped on — it reads
`pricing_configuration->>'refund_application_fee'` live at `:92`, which is the defect. Its
name is an operational contract (`docs/operations/sacp-stripe-connect-onboarding.md:202`)
and the name survives, but **the signature does not**: it becomes
`refund_application_fee_for_payment($db, $payment)` in Leg 9a, reading the stamp, with the
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
the stamp until Leg 9a — that a stamp needs an immutable version behind it to record anything
true — does not apply to a routing identifier, which is true the moment the charge is
created. Leg 3 is the leg that must merge before the first tenant onboards, and leaving the
column until Leg 9a means every charge in a 20-to-30-day window is unreconcilable and
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
`stripe_account_id` and Leg 9a's quote columns take that loop.

**The loop is necessary and not sufficient, because the tenant copy of an object does not
carry the same name.** `clone_schema` builds each tenant table with
`CREATE TABLE … (LIKE registry.<t> INCLUDING ALL)`
(`sql/deploy/fix-clone-schema-identifier-quoting.sql:367`), and Postgres regenerates index,
primary-key and unique-constraint names to its defaults when copying that way. The follow-up
loop that re-creates constraints under their original names filters `ct.contype = 'f'`
(`:385-391`) — foreign keys only. CHECK constraints do keep their names, which is why Leg 3's
`enrollments_refund_status_check` widening is unaffected; indexes and unique constraints do
not. Verified read-only against the dev database, which has one tenant schema: `registry`
holds `enrollments_session_student_type_unique` and `idx_payments_stripe_intent`, while
`sacp` holds `enrollments_session_id_student_id_student_type_key` and
`payments_stripe_payment_intent_id_idx`. The names diverge by vintage —
`sql/deploy/flexible-enrollment-architecture.sql:26,64` gave the custom name to `registry`
and to the tenants that existed when it ran, and every tenant cloned since got the default.

So a tenant-loop `DROP CONSTRAINT enrollments_session_student_type_unique` aborts the sqitch
change on `sacp`, and the `IF EXISTS` form the house uses in its reverts
(`sql/revert/flexible-enrollment-architecture.sql:28`) converts that into a silent skip,
which is worse: it leaves the status-blind constraint in force in the one schema that has
money in it. **Any migration in this milestone that drops or replaces an index or a unique
constraint in a tenant schema resolves it from `pg_index`/`pg_constraint` by table and column
set, never by name, and does not use `IF EXISTS`.** The house pattern hides this by luck —
`sql/deploy/remove-waitlist-position-constraint.sql:21` drops
`waitlist_session_id_position_key`, which works only because that already is the Postgres
default name. Leg 0 is where the first two instances land.

It is worth knowing that **no test will catch its absence.** `sql/test-schema.sql` contains
`registry`, `sqitch` and `public` and no tenant schema at all, so the loop body never
executes under `make test-schema` and a migration that omits the loop entirely passes the
suite. The tenancy invariant test under "Testing" — which onboards a tenant — is the only
thing in the design that would notice, and it is extended to assert the column set of
`<tenant>.payments` matches `registry.payments` for exactly this reason. The same test carries
the name-regeneration half: it asserts the *constraint and index set* by column list rather
than by name, and Leg 1's revert-test harness runs against a schema built by `clone_schema`
rather than against `registry` alone, because a harness that only exercises `registry` cannot
see this class of failure at all.

**Stamping requires a mutator that `Payment` does not have.** `Payment::save`
(`Payment.pm:425-435`) writes a fixed six-column list, and every field is `:param :reader`
with no writer, so there is nowhere to put a quote before saving it. Leg 9a extends both: the
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
the older one. And its **revert is a second full copy of the function** — roughly 236 lines,
`fix-clone-schema-identifier-quoting.sql:247-482`; 484 is the file, not the function —
because reverting `CREATE OR REPLACE` means replacing it back, and an empty revert
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
`Entitlement` do the tenant-schema tables get dropped, in Leg 9b with the other deprecated
columns.

Two practical consequences of the two shapes. Leg 4's migration must **normalize before it
copies** — add the missing columns to old-shape tenant tables first, with the same
`CONTINUE WHEN NOT EXISTS` schema guard `sql/deploy/pricing-plans-amount-cents.sql:39-60`
already uses — rather than assuming a uniform source. And Leg 9b's revert cannot honestly
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

**The rule is about anything that puts a function in `registry`, not about trigger functions.**
An earlier draft drew this conclusion for Leg 4's four triggers and stopped there, which left
Leg 7's `CREATE EXTENSION` — 212 functions rather than four, and `LANGUAGE C` rather than
`plpgsql`, which turns dead weight into a production-only failure of tenant onboarding. The
general form: **`registry` is a schema `clone_schema` copies out of, so nothing belongs in it
that a tenant should not have its own copy of.** Every leg that creates a function, a
procedure, or an extension names `public` explicitly. Today that is Leg 4 and Leg 7; the rule
exists so the next one does not have to rediscover it.

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

**One parameter, and a unit conversion the design has not written down.** `2` in that request
is a *percent*. Everything Registry stores and passes is a *fraction*:
`RevenueShare.pm:1-2,15` documents the return as "0.02 for 2%", and `_coerce_pct` (`:143-156`)
enforces it, dying on anything outside `[0,1]`. Today that never matters, because the only
consumer is `Payment.pm:91,96` computing `application_fee_amount` in cents — a multiplication,
where the fraction is the right unit. Leg 8 adds the second consumer, and it needs
`fraction * 100`. Omit the conversion and Stripe reads `0.02` as **0.02 percent**: Registry
collects two hundredths of a percent of every membership invoice, a 100× undercharge that
produces a plausible non-zero fee and therefore no error anywhere. Invert the conversion by
writing the percent into the plan instead and `_coerce_pct` dies at authoring — which is the
safe failure, and the reason the fraction convention stays. So: **the plan stores a fraction,
`application_fee_amount` multiplies it, `application_fee_percent` multiplies it by 100, and
Leg 8's invariant test asserts a 2% plan produces `application_fee_percent=2` and not
`0.02`.** This is the same class of defect as the `rate`/`percentage` unit mix already fixed
once on this branch, at the one site where the units genuinely differ.

**The conversion also has a precision ceiling the fraction column does not.**
`application_fee_percent` takes *"at most two decimal places"* — so the representable rates are
`0.01%` steps, and a fraction is a `NUMERIC` that will happily hold `0.025333`. A plan authored
at a rate that does not survive the ×100 to two places is a plan whose subscription fee is
silently rounded away from what the quote says. Leg 4's authoring CHECK constrains the fraction
so the product of the conversion is representable — four decimal places on the fraction — which
is the same "unauthorable rather than merely unwritten" discipline Pillar 5 asks for, applied
to a limit Stripe imposes downstream. Note this binds only the `percentage`/`recurring` path;
`application_fee_amount` is an integer in cents and has no such limit.

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
credited. They arise from the pure-percentage case that **ships**, and the ones raised outside
the cycle collect nothing for Registry while looking exactly like a working charge. That is the
same revenue hole (12) was written to close, one billing event further in.

**And then a later draft over-read it in the other direction, which is the third self-inflicted
error in this document.** The sentence that stood here said "a proration does not collect a
*reduced* fee, it collects **zero**," unqualified. That is wrong for the common case. Stripe's
escape clause is scoped twice over: the parameter *"doesn't apply to invoices you create
**outside of a subscription billing period**,"* and the proration example is *"proration
invoice items that are **immediately invoiced**."* The same page says the fee is taken from
*"the final invoice amount, **including any bundled invoice items**."* A default
`proration_behavior: 'create_prorations'` does not invoice immediately — it leaves a proration
invoice item that lands on the next cycle invoice, bundled, and the percentage *does* apply
to it.

So the hole is real but narrow: it opens only where a proration is **immediately** invoiced —
`proration_behavior: 'always_invoice'`, or any invoice raised outside the cycle — and there the
fee is zero unless the platform sets `application_fee_amount` on that invoice. It is not the
whole of prorations, and the deferral of the `invoice.created` handler is not the revenue hole
the previous sentence made it.

The deferral survives, narrowed and with the consumer named. The `invoice.created` handler
still waits — it is the 72-hour-stall handler and it is not something to ship in the same leg
as the subscription itself — but **the milestone does not get to be unaware of prorations**.
Two things ship instead. `PriceOps::Schedule` passes `proration_behavior: 'none'`, so a
mid-cycle change produces no uncollected proration rather than a silent one; the family is
billed the new rate from the next period. And the follow-up list carries the handler with its
actual trigger, which is *the first tenant who wants mid-cycle upgrades*, not *the first tenant
who wants a hybrid plan*. Choosing `none` is a product decision as much as a technical one and
it is recorded as such: it is the option that cannot lose money quietly, and the one to revisit
deliberately. The narrowing above does not change that choice — `none` was never the only
option that collects, it is the only one with no uncollected-proration case at all — but it
does change what the choice is *defending against*, from "every proration" to "an
`always_invoice` proration or an out-of-cycle invoice." An implementer who reads the old
sentence and then sets `create_prorations` has not lost the fee, and should not be told he has.

**`proration_behavior` is a request parameter, not a subscription setting, and "`Schedule`
sets it on the subscriptions it creates" was the wrong sentence.** It is scoped to the request
that carries it — on create it governs only the proration implied by that request's
`billing_cycle_anchor`, and it is not persisted onto the Subscription to govern later changes.
Setting it once at creation prevents nothing. So the obligation is a code rule rather than a
config value: **every Registry request that modifies a subscription passes
`proration_behavior: 'none'` explicitly**, and `PriceOps::Schedule` is the only module allowed
to issue such a request, so that there is one place to enforce it. A tenant changing a
subscription from their own Dashboard is outside that rule entirely — `dashboard: full` means
they can, and their proration is theirs.

Four Stripe restrictions bind the shipping half and belong in the design rather than in a
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
| KYC | `requirements_collector: stripe` | **Not a choice.** Stripe computes it: *"automatically calculated based on the `losses_collector` and `dashboard` values. You can't set it."* With losses on Stripe and a full Dashboard, Stripe collects and maintains verification, including when requirements change. |

**Which of these can be walked back is the opposite of what an earlier draft claimed, and the
answer is now "none of the responsibilities."** That draft marked `dashboard` immutable and
the collectors negotiable. Both halves invert. `dashboard` *is* mutable — it is a documented
parameter of `/v2/core/accounts/update`, and Stripe says *"We send the
`v2.core.account.updated` event only for updates to top-level properties, such as `dashboard`
or `display_name`."* The responsibilities are not, and not just `fees_collector`:

> "You must define `defaults.responsibilities` properties when you add the Merchant
> configuration to an account. You can't update their values later."

plus, on the fee payer specifically, *"You can specify the fee payer only when you create an
account."* So `losses_collector` and `fees_collector` are **both one-way doors**, decided once
per tenant at `POST /v2/core/accounts`, forever. A later draft filed `losses_collector` as "the
single choice in this design with a company-shaped consequence" and sent the spike to ask
whether it was updatable after creation. The docs answer that: no. What remains
company-shaped is the *decision*, not its reversibility, and it is made here rather than
deferred — `losses_collector: stripe`, because Registry is one person and cannot be a risk
operation, which is the same reason the row gives.

Two spike questions therefore close before the spike runs: the KYC row is documented rather
than inferred, and collector mutability is documented rather than open. What is left for Leg 3a
is listed under "Sequencing" and is smaller than it was.

**And `dashboard: none` does not buy back what the fallback assumed it did.** The fixture
question below turns on who may submit verification data on the account's behalf, and that is
`requirements_collector` — which, per the row above, Stripe derives from `losses_collector`
*and* `dashboard`, not from `dashboard` alone. Making Registry the requirements collector
requires `losses_collector: application`, and Stripe's configuration matrix ties that to
`fees_collector: application`: the platform takes negative-balance liability *and* fronts
Stripe's processing fees, then bills them back. That is not a smaller version of this design,
it is the inverse of its fee model and of the reason `losses_collector: stripe` was chosen.
The named fallback under "Sequencing" is rewritten accordingly.

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

**The collapse moves out of Leg 3 and into Leg 9b**, with the column drop it was always paired
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
predates Accounts v2 entirely. The pin is not incidental: `t/stripe-live/service-version.t`
exists solely to catch it drifting, and `DAO::Subscription.pm:71-103` is a *third* Stripe
client that sends no version header at all. Bumping a pinned version is a change to every v1
call Registry makes, across a year and a half of Stripe releases, and it is not something to
discover halfway through Leg 3. **It ships as its own leg, before Leg 3** — see Leg 3a.

**The target is `2026-07-29.dahlia`, and naming it exactly is the point of this paragraph —
which is also where this document has been wrong twice.** The first draft said "a
`2026-07-29` version" without a train. A review round then asserted the v2 doc pages send
`2026-07-29.preview` — "the public-preview channel rather than a GA release train" — and that
correction was folded in and is **false**. `docs.stripe.com/api/v2/core/accounts/create` and
`docs.stripe.com/api/v2/core/event_destinations/create` both send
`Stripe-Version: 2026-07-29.dahlia`. There is no preview channel in play. Recording the wrong
version here rather than deleting it, because it was in this document and in the leg table,
and a leg whose entire content is pinning a version is the worst place to carry a wrong string.

Dahlia's first version is `2026-03-25` and `2026-07-29` is an additive monthly on the same
train, so the two differ by no breaking change and both are GA. **Leg 3a pins
`2026-07-29.dahlia`** — the later of the two, because it is what Stripe's own Accounts v2
examples send, which makes it the version the v2 request shapes in this design were read
against. `service-version.t` asserts that exact string.

**Three breaking trains sit between acacia and dahlia, not one.** An earlier draft grounded
Leg 3a's whole risk case on `2025-03-31.basil`'s Invoice removals and sized the leg from a
grep for one field. Basil `2025-03-31`, Clover `2025-09-30` and Dahlia `2026-03-25` are all
breaking, and the entries that land on Registry's surface include several no grep finds:
Clover makes **flexible billing mode the default for new subscriptions** (Registry creates
subscriptions and passes no `billing_mode`, so this is a behaviour change with no compile
signal); Clover moves platform-specific identity fields to a **`defaults.profile`** on
Accounts, removes the Discount `coupon` property and the subscription-schedule `iterations`
parameter; Clover `2025-12-15` makes **Accounts v2 always return `responsibilities` when
`defaults` is included** — the exact field the spike asks about; Clover `2025-11-17` changes
**requirements-collection parameters for Accounts v2**; Dahlia changes **`events_from` on
event destinations** to accept string values, which this design's v2 destination uses.

So **Leg 3a's first task is a full acacia→target changelog diff across all three trains and
the intervening monthlies**, filtered to Billing, Connect, Payments and Invoicing. The five
`invoice.subscription` call sites are a floor, not a scope, and the leg is re-costed after
the diff rather than before it. The compile-time exposure really is small — `grep -rn
"invoice->{payment_intent}\|invoice->{charge}\|latest_invoice" lib/` returns one hit — which
is exactly why the behavioural changes are the ones that cost a session.

**Stripe.js is part of the version question and the earlier draft left it out.** Leg 3a as
written bumps the server only, leaving `templates/tenant-signup/payment.html.ep:129` and
`templates/summer-camp-registration/payment.html.ep:141` on `js.stripe.com/v3/` — a
cross-train split Stripe advises against: *"each versioned Stripe.js automatically uses the
API version associated with the Stripe.js version… **You can't override the API version**"*,
and it recommends keeping both on the same release train. This is **not** a latent-breakage
risk the way an earlier round of this review assumed: Stripe is explicit that v3 is evergreen
and receives no breaking changes, so staying put is safe. It is a decision Leg 3a must
*record* rather than leave implicit. Moving the two script tags to `/dahlia/stripe.js` is
cheap and clear — Registry's entire client surface is `Stripe()`, `elements()`,
`elements.create('payment')`, `mount`, `confirmPayment`/`confirmSetup`, and all six Dahlia
`stripejs` breaking changes miss it. Two script tags, not a rewrite.

*OAuth is given up, and this is the one that surprised the fourth reviewer.* Stripe lists
using *"OAuth to authenticate connected accounts"* among the cases where **"You must use
Accounts v1"**. Choosing v2 therefore ends OAuth as an onboarding mechanism, and with it
`/v1/oauth/deauthorize`. An earlier draft said a v2 account "uses the rejection API instead";
that was invented. See "disconnect" under "Money movement" for what actually replaces it.

**`account.application.deauthorized` survives, and this is now settled rather than open.**
Two drafts got it wrong in opposite directions: the first bundled it into the OAuth loss
without checking, the second said it "may survive" and sent Leg 3a to confirm. Stripe gates
the event on Dashboard access, not on OAuth, and says so twice — the event reference gives
*"Occurs when a connected account disconnects from your platform… **Available for connected
accounts with access to the Stripe Dashboard**, which includes Standard accounts,"* and the
Connect subscriptions page lists it under the same condition. `dashboard: full` meets it.

So the event exists under this configuration, and **the three places in this document that
say it does not are wrong**: the disconnect section's "with OAuth gone there is no
`account.application.deauthorized` to hook," decision (24)'s claim that it disappears with
OAuth, and the risk framing here. They are corrected in place. What does **not** change is the
design: Registry-initiated disconnect is still the primary mechanism, because the event tells
us a tenant has already left and the fee removal has to happen *before* they do. The event
becomes a reconciliation backstop — the signal that the Registry-initiated path was skipped —
which is a smaller job than the handler (13) originally specified, and it comes off Leg 3a's
question list.

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
have become *mandatory* and moved into Leg 3 — which is the main reason not to choose it, and
as the responsibilities discussion above establishes, `dashboard: none` on its own would not
even have bought back platform-side KYC in exchange.

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
an embedded component reimplementing submission.

**This contradicts the leg table and the contradiction is left standing for perigrin, not
resolved silently.** The Leg 12 row still reads "admin page, embedded components,
AccountSession … widen the CSP," which is the costing for the embedded build; this paragraph
argues for a list view and a deep link, which needs neither AccountSession nor the CSP change.
Both are defensible and they are different legs:

- **List view + deep link.** Smaller — no AccountSession, no CSP widening, no embedded
  component to keep working across Stripe releases. Loses in-Registry evidence submission; a
  tenant handling a dispute leaves for the Stripe Dashboard. Estimated 2-3 rather than 3-5.
- **Embedded components.** What the row costs today. Keeps the whole dispute flow inside
  Registry, which matters if the eventual answer on `dashboard` is `none`. Carries
  AccountSession, the CSP widening at `Registry.pm:524,527`, and a component surface that
  Stripe versions independently.

The list view is the recommendation, because under `dashboard: full` the embedded build is
duplicative of a UI the tenant already has with Stripe's support behind it. **perigrin picks.**
Leg 12 is position 15 and depends on Leg 9a, so the decision is not urgent — but it should not
be discovered by whoever files the issue. Revisit either way if `dashboard` ever moves.

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
4. Emit one line per component of the resolved version — no filter. (`applies_to`, and the
   event vocabulary that would give a filter something to match on, arrive together in
   Leg 10; see the deferral above.)
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
so `refund_application_fee_for_payment` — the renamed function, one paragraph up — reads the
terms stamped on the payment row rather than quoting afresh. `Payment.pm:114` resolves from the tenant's *current* plan today, which
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
  the webhook calling that. Leg 0 owns it, and Leg 9a extends the same field list and column
  list for the quote stamp.
- **Reconciliation.** `Registry::Job::ReconcilePayments`, registered like the existing
  jobs (`Registry.pm:72-75`) **and scheduled on the cron Leg 3 repairs — `Registry.pm:72-75`
  is `add_task` and nothing more, and a job registered but never enqueued is the drift detector
  itself failing silently**. It retrieves the intent and writes down what Stripe says —
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

  **That list was a third of the work.** A subscription needs someone to bill and something to
  bill them with, and this document's entire treatment of both is one clause — "families become
  Customers on the tenant's account" — which appears twice, is assigned to no leg, and is
  itemized in no row. Stripe requires `customer` on `POST /v1/subscriptions`, and a
  `charge_automatically` subscription with no default payment method is created `incomplete`
  and settles no invoice. None of the pieces exist: family enrollment is guest checkout
  (`DAO/Payment.pm` sends no `customer` and no `setup_future_usage`, and
  `templates/summer-camp-registration/payment.html.ep:164` is a one-shot `confirmPayment`),
  there is no `Stripe-Account` plumbing anywhere in `lib/` or `templates/`, and the only
  `stripe_customer_id` column in the schema is on `registry.tenants`
  (`sql/deploy/stripe-subscription-integration.sql:10`) — a platform-side column that cannot
  hold a family's id on a *connected* account anyway, since a family enrolling with two tenants
  needs one Customer per account. So **Leg 8 additionally owns**: a SetupIntent (or
  `setup_future_usage` on the enrollment PaymentIntent) issued with `Stripe-Account` so the
  method is saved on the tenant's account, the Customer created there, a per-tenant-schema
  column holding that customer id, and a stated answer to whether the recurring charge reuses
  the enrollment's payment method or requires its own consent step. Leg 9a's `customer_account`
  swap does not cover any of this — that is the Registry→tenant direction.

  **And nothing records the money when it arrives.** No leg specifies a handler that writes a
  `payments` row when one of those invoices settles: `invoice.paid` and
  `invoice.payment_succeeded` appear nowhere in this document, and the only invoice event it
  does name is the deferred `invoice.created` hybrid. Meanwhile Leg 1 deletes the repo's only
  `invoice.paid` code, because `Webhooks.pm:204-227` classifies it by resolving
  `PaymentSchedule` against a table Leg 1 drops. What survives is
  `DAO::Subscription::process_webhook_event` (`:225-241`), which handles five types, writes no
  `payments` row from any of them (`_handle_payment_succeeded` at `:327-338` only sets
  `registry.tenants.billing_status`), and silently marks everything else `processed` at
  `:244-247`. The one-time path cannot absorb it either: `Webhooks.pm:98-101` returns unless
  `$intent->{metadata}{payment_id}`, which an invoice-generated PaymentIntent never carries.
  The envelope rule says an account-bearing event "routes to the enrollment path" and never
  says what that path does with an invoice.

  Scope this honestly: **no money is lost.** Stripe still collects Registry's share from
  `application_fee_percent` and the tenant's funds still settle into the tenant's account. What
  breaks is everything downstream of the local record — the revenue is invisible to
  `AdminDashboard.pm:36`, unrefundable because `Payment::refund` needs a row, unstampable with
  a quote for Leg 12's dispute join — and, decisively, **Leg 13's acceptance criterion 5 asserts
  one payment row after the invoice-settling webhook is replayed twice**, so the milestone's
  single pass/fail gate is unexecutable until this handler exists. Leg 8 owns it, and the
  dunning question is already answered elsewhere in this document: a parent's declined card
  must not mark the *tenant* past due, which is why the envelope rule refuses to derive
  `tenant_id` from `event.account`.
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
  and moving the row to `refunded` or `refund_failed` on the answer. (One correction to that
  sentence: `SKIP LOCKED` appears nowhere in `lib/`, so it is the right shape but not an
  existing one to copy.)
- **A poller only recovers money if something re-enqueues it, and nothing in this repository
  currently can.** This is the finding that makes the two jobs this milestone adds —
  `ProcessRefunds` here and `ReconcilePayments` in Leg 12 — worth registering and still not
  worth anything. There are exactly two recurring-enqueue mechanisms and both are broken.

  The Render cron (`render.yaml:96-110`, every five minutes) reaches
  `docker-entrypoint.sh:81-85`. Its `envVars` list carries `registry-database`,
  `registry-config`, `MOJO_MODE=production` and `SERVICE_TYPE=scheduler` — and **not**
  `MOJO_SECRET`, which the worker gets through a `fromService` block at `:87-91` that was never
  copied down. `Registry.pm:36` dies without it in production. Every run since the service
  booted has failed the same way, and this is observed rather than inferred: the Render logs
  for `crn-d311bqgdl3ps73dv3lb0` are `Starting scheduler tasks...` →
  `MOJO_SECRET environment variable is required in production at lib/Registry.pm line 36.` →
  `Exited with status 255`, on every run across the whole ~7-day retention window. Underneath
  that, the two commands are also wrong: `./registry job attendance_check` cannot resolve —
  `lib/Registry/Command/` holds five commands and none is `job`, Mojolicious ships none, and
  Minion's is `Minion::Command::minion::job`, reached as `./registry minion job -e <task>`. And
  `set -e` at `docker-entrypoint.sh:6` means the first failure aborts the script, so the second
  task would never run even if the first were fixed.

  The in-process alternative is no better. `setup_recurring_jobs` (`Registry.pm:830-898`) is
  called once, from `before_server_start` (`:479`), and each block enqueues a single delayed
  job only when the task has none inactive or active. Nothing re-arms it, so on a stable deploy
  each sweep runs once per boot, ever. Production shows exactly that: the worker booted
  2026-08-02, ran `attendance_check` once, `waitlist_expiration` once, `process_waitlist` once,
  and has emitted nothing since.

  So **Leg 3 fixes the scheduler as part of shipping the first job whose failure is a money
  failure**: the `MOJO_SECRET` block copied onto the cron, `./registry minion job -e <task>` in
  place of `./registry job <task>`, the two new tasks added there, and one test asserting that
  every task name enqueued anywhere in `lib/` or `docker-entrypoint.sh` exists in the `add_task`
  registry. Leg 12's `ReconcilePayments` inherits it and has no alternative — `ProcessRefunds`
  could in principle be enqueued on approval instead of polled, but a drift sweep has no
  triggering event by construction. The instruction both legs currently carry, "registered like
  the existing jobs (`Registry.pm:72-75`)", is `add_task` and nothing else, so following the
  spec literally produces a job that is registered and never runs — which is the same
  CI-green/production-dead shape as (50), one layer up.
- **The job would find nothing, because no production path writes `'pending'`.** The bullet
  above cites `DropRequest.pm:68` as the writer. It is the *only* writer that would produce a
  claimable row — and `DropRequest->approve` (`:47`) has **zero non-test callers**; the six
  `->approve(` hits in the repository are all under `t/`. Production goes through the workflow
  chain instead, and the chain drops the flag on the floor: `ProcessEnrollmentDrop.pm:38`
  writes `refund_status => $data->{refund_requested} ? 'pending' : 'none'`, but the
  `drop-request-processing` run is created by `ProcessAdminDropDecision.pm:19-26` with
  `{drop_request_id, action, admin_notes, refund_amount_cents, admin_user_id, admin_approved}`
  and **no `refund_requested`**, and `ValidateDropRequest.pm:36-41` — which does load the
  `DropRequest` object carrying `refund_requested` (`DropRequest.pm:12`) — returns
  `drop_request_id`, `enrollment_id`, `session_id` and `validation_passed` without it. So the
  key is undef, the ternary takes the false branch, and the enrollment is cancelled with
  `refund_status = 'none'` **and** `refund_amount_cents` set to the amount the admin just
  typed. `ProcessDropRefund.pm:14` then short-circuits on the same missing key and reports
  "No refund requested" — its `:28` write of `'pending'` is unreachable for the same reason.
  This is worse than the bullet above describes: it is not that a `pending` row sits unclaimed,
  it is that the row is marked settled with a refund amount recorded against it. An operator
  reading the enrollment sees a dollar figure and a status that says nothing is owed.
  **Leg 3 therefore ships the propagation before the job**, or the job is dead code the day
  it merges: `ValidateDropRequest` returns `refund_requested => $drop_request->refund_requested`,
  and `ProcessEnrollmentDrop` keeps the ternary it already has. The acceptance condition is an
  end-to-end assertion through the workflow chain — not a unit test on `approve`, which is the
  method nothing calls.
- **A drop before the session starts can never be refunded at all.**
  `Enrollment::request_drop` (`:238`) branches on `$session->has_started`: only a started
  session routes to the `DropRequest` approval path. Everything else — every pre-start
  cancellation, and every admin-initiated drop at any time — goes to `_process_immediate_drop`
  (`:259`), whose signature is `($db, $user, $reason)`. It does not take `$refund_requested`,
  the caller's argument is discarded at the branch, and `:274` hardcodes
  `refund_status => 'none'`. A parent who paid in full and cancels a week before the first
  class asks for their money back and the column records that none is owed. (`:259` is the
  call; the method is defined at `:263`.) There is no
  approval queue for this case and no row for a refund job to find. This is the more common
  case of the two, not the edge one: pre-start cancellation is the normal way an after-school
  enrollment ends early. Leg 3 gives `_process_immediate_drop` the refund parameter and the
  same `'pending'`/`'not_applicable'` write the approval path uses; whether a pre-start drop
  is *automatically* refundable is a policy question for the tenant, and Leg 4's plan
  `requirements` are where a cancellation policy would eventually live. Recording the request
  is not the policy — it is the precondition for having one.
- **Accepting a waitlist offer enrolls the child for free, and this document has never used
  the word "waitlist".** `Waitlist->accept_offer` (`:187-226`) creates the enrollment directly
  — `Registry::DAO::Enrollment->create($db, {… status => 'pending', metadata => {from_waitlist
  => 1}})` at `:200-208` — with no quote, no `Payment` row, and no route through
  `WorkflowSteps/Payment`. Its caller, `Controller/Waitlist.pm:86`, then flashes *"Successfully
  enrolled … in "* the session name at `:93-94`. So a parent who waits for a spot in a paid
  program is told they are enrolled and is never asked for money, and the tenant's roster shows
  a child who paid nothing next to children who paid in full. Waitlist progression is
  *automated* — the Minion job promotes from the waitlist on a drop — so this fires without
  anyone deciding to fire it.

  It is the same defect as the unpriced-enrollment hole Leg 0 closes in
  `calculate_enrollment_total`, on a code path that never calls it. **Leg 8** owns it, because
  Leg 8 is where `Entitlement->quote` exists and where the charge is rewired: `accept_offer`
  quotes, and either creates a payment-pending enrollment that the ordinary payment step
  settles, or — for a genuinely free session — records a zero quote explicitly rather than by
  omission. The `status => 'pending'` it already writes is the right hook; nothing consumes it
  as "unpaid" today. Until Leg 8 lands, a tenant with a paid program and a waitlist is losing
  the full price of every promoted spot.
- **The storefront and the checkout are two different pricing engines, and they disagree in
  the direction that gives the program away.** `WorkflowSteps/ProgramListing.pm:102` runs its
  own `SELECT * FROM pricing_plans WHERE session_id IN (…)` and picks a price at `:149-154` by
  taking the numeric minimum of `amount_cents` across the plans. `DAO::Payment::calculate_enrollment_total`
  (`:499-546`) takes `$pricing_plans->[0]` at `:517-521` and calls
  `$pricing->calculate_price(…)` at `:522`. Three separate divergences, all of them live:

  - **Selection.** `min()` versus "the first row the query returned." A session with an
    early-bird plan and a standard plan advertises the early-bird price on the storefront and
    charges whichever row Postgres hands back first.
  - **Requirements.** `PricingPlan::calculate_price` opens with `return unless
    $self->requirements_met($context)` (`:138`, defined at `:152`) — the storefront's inline
    SQL has no filter of any kind, so it prices against plans the buyer does not qualify for.
  - **The failure mode.** When requirements are *not* met, `calculate_price` returns `undef`,
    `calculate_enrollment_total:528` skips that child, and the cart total is short by one
    child — or zero, for a single-child enrollment. The storefront meanwhile displayed a price.
    So the advertised-versus-charged gap is not a display bug; it is the mechanism by which an
    expired early-bird window produces a free enrollment.

  Leg 0's "refuses an undefined price instead of skipping the child" closes the third of these
  and leaves the first two. **Leg 4 owns the unification**, because Leg 4 is already repointing
  `ProgramListing.pm:102` at the registry table and is the last moment the two engines can be
  merged without merging them twice: the storefront reads the same resolver the checkout does.
  Until Leg 8 that resolver is `calculate_enrollment_total`; after Leg 8 it is
  `Entitlement->quote`, and the storefront moves with everything else. What must not happen is
  Leg 4 repointing the inline SQL at a new table and leaving it inline — that preserves the
  divergence across the whole milestone and makes it harder to see, because both engines would
  then be reading the same rows and still disagreeing.
- **A staff user can approve their own refund, and the amount is only checked for shape.**
  `Registry.pm:678-680` guards `/admin` with `require_role('admin', 'staff')`, and `:690`
  routes `POST /dashboard/process_drop_request` into the `admin-drop-approval` workflow under
  that same guard. Refund approval is therefore available to every instructor, not to
  administrators. The amount is worse than unguarded: `AdminDropDecision` validates
  `refund_amount` as a number and converts it to cents, and nothing compares it to the payment
  it will be refunded against — and because a family cart is **one** payment row covering
  every child, the row a per-child drop refunds from is the whole family's. A typo of a
  decimal point refunds more than the enrollment cost, from the tenant's balance.

  Two fixes, both in **Leg 3** with the rest of the refund path: the route moves under an
  `admin`-only `under`, and `Payment::refund` caps at `amount_cents - sum(prior refunds)` —
  which is the same running total the partial-refund bullet below already requires, so the cap
  is one comparison against a number that has to be computed anyway. The authorization half is
  independent of this milestone and gets its own issue as well, because it is live today.
- **A dropped connection between the Stripe POST and the tenant UPDATE orphans a live
  subscription, and the crash is a type error rather than a timeout.**
  `DAO::Subscription.pm:140-155` creates the subscription at `:140`, returns early at `:141`
  if the call failed, then at `:145` builds
  `DateTime->from_epoch(epoch => $subscription->{trial_end})` before the `UPDATE registry.tenants
  … SET stripe_subscription_id = …` at `:147-148`. When `trial_end` is absent — which is every
  Solo tenant, because `TenantPayment.pm:124` passes `trial_days => 0` and the `//= 30` default
  at `:147` does not rescue a defined zero — `from_epoch` is called with `epoch => undef` and
  **dies**. Verified by running it. Stripe has the subscription; Registry writes no
  `stripe_subscription_id`, no `billing_status`, and no `trial_ends_at`. The tenant is billed
  monthly by a subscription Registry cannot see, cancel, or attribute.

  This is the identical shape to the idempotency hole two bullets down, arriving by a different
  route: there, a dropped connection loses the id; here, a defined-zero trial does. **Leg 0**
  owns both, and the fix is the same discipline the leg is named for — the tenant write happens
  in the same transaction as the create's result, `trial_end` is read defensively, and a
  subscription whose id cannot be recorded is cancelled rather than left running.
- **A payment can be partially refunded exactly once, and the second attempt dies.**
  `Payment::refund` opens with `die "Cannot refund non-completed payment" unless $status eq
  'completed'` (`:449`) and closes by setting `$status = 'partially_refunded'` when the refund
  is less than the full amount (`:469-473`). The two lines contradict each other: after one
  partial refund the row is no longer `completed`, so the next call to the same method on the
  same payment throws. Refunding one child out of a three-child family cart is exactly this
  shape, and it is the case an after-school business hits first. The bookkeeping under it is
  single-valued too — `:475-477` writes `refund_id`, `refund_amount_cents` and `refund_reason`
  as scalars into `metadata`, so a second refund would overwrite the first's record rather
  than append to it, and the `$refund_cents >= $amount_cents` test at `:469` compares *this*
  refund against the full amount rather than the running total, so two partials that sum to
  the whole leave the row `partially_refunded` forever. Leg 3 owns this because Leg 3 rewrites
  the refund parameters anyway: the guard becomes "refundable while
  `sum(refunds) < amount_cents`", the metadata scalars become a list, and the status is derived
  from the sum. Stripe already models it this way — a PaymentIntent carries many Refunds — so
  this is Registry disagreeing with the API it is calling, not a gap in the API.

  **The idempotency key proposed for refunds collides on the legal case.** The bullet above
  derives it "from the payment id and amount," which is exactly the key two *different*
  refunds share when a parent drops two children from the same family cart at the same price.
  Stripe replays the first response for 24 hours, so the second refund silently does not
  happen and returns a success. Derive it from the refund's own identity instead — the
  `drop_request_id`, or the enrollment id plus a sequence — never from an amount, which is not
  unique by construction. **The rule is every refund Registry issues, not only drop-initiated
  ones**: Leg 0's capacity-at-capture refund has no `drop_request_id` and ships before this
  leg, so it carries its own key (`refund:capacity:<payment_id>`) and Leg 0 is what gives
  `Service::Stripe::create_refund` a key parameter at all.

  **And the reuse guard one layer up erases a refund.** `WorkflowSteps/Payment.pm:154` reuses
  an existing payment row when `$existing->status ne 'completed'` — a deny-list of one. Every
  other status passes it, including `refunded` and `partially_refunded`. A parent who was
  refunded and re-enrolls reuses the refunded row and drives it back to `completed`, and the
  refund's record in `metadata` goes with it. The guard belongs the other way round: reuse only
  a row in a status that is genuinely mid-flight (`pending`, `processing`), and create a new row
  for anything else. **Leg 0**, with the `FOR UPDATE` and the unique index, because it is the
  same "read, decide, write, on a row nothing is holding" shape.

  **The statuses all three of these write do not exist in the schema.**
  `enrollments_refund_status_check` (`sql/test-schema.sql:838`) allows exactly `none`,
  `pending`, `approved`, `processed`, `denied`. This document has Leg 3 writing
  `not_applicable` on a pre-start drop and `refunded`/`refund_failed` from
  `Job::ProcessRefunds`, and every one of those raises a check violation — inside the Minion
  job, after the Stripe refund has already succeeded. Leg 3's only migration as currently
  listed is `payments.stripe_account_id`. It needs a second: either widen the constraint or map
  onto the existing vocabulary (`processed` for success, `denied` for a failed attempt,
  `none` for not-applicable). Widening is the better answer — `denied` means an admin said no
  and `refund_failed` means Stripe said no, and collapsing them loses the distinction an
  operator needs — but either way the constraint is part of Leg 3, not a discovery in it.
- **The Stripe destination account is selected by an attacker-writable POST parameter.** This
  is the largest single hole in the money path and no earlier round found it, because every
  round looked at the payment step and none looked at how the payment step's input arrives.
  `DAO/Payment.pm:74-97` derives `transfer_data[destination]`, `on_behalf_of` and the
  revenue-share fraction from one string, `$metadata->{tenant_slug}`; `WorkflowSteps/Payment.pm:124`
  and `:205` take that string from `$run->data->{__tenant_slug}`. The controller sets
  `__tenant_slug` from `$self->tenant` — the verified Host header — but **only in `new_run`**
  (`Workflows.pm:52-58`). Every subsequent step is `my $data = $self->req->params->to_hash;`
  with no override (`Workflows.pm:351`), the base step class returns its input unchanged
  (`WorkflowStep.pm:205-214`, "Default implementation - simple passthrough"),
  `@TRANSIENT_KEYS` does not list `__tenant_slug` (`WorkflowRun.pm:81-84`), and the persist is
  a jsonb `||` merge in which the later write wins (`WorkflowRun.pm:156-158`). So a POST body
  carrying `__tenant_slug=some-other-tenant` to any passthrough step overwrites the
  server-derived value for the rest of the run. `summer-camp-registration.yaml` has such a step
  two positions before payment: `camper-info`, `class: Registry::DAO::WorkflowStep`.

  The consequence is not a leaked read, it is a misdirected settlement: tuition for tenant A's
  program settles into tenant B's connected account, `on_behalf_of` makes B the merchant of
  record for a charge B never sold, and the application fee is computed from B's plan rate.
  Registry finds out when A asks where the money went.

  **The fix is one line in the right place, and the right place is not the payment step.**
  `__tenant_slug` is a server-derived fact, so the controller applies the same override on
  every step, not only the first — the two paths at `Workflows.pm:52-58` and `:351` become one
  helper. Adding `__tenant_slug` to `@TRANSIENT_KEYS` is the wrong shape: it would strip the
  legitimate value too. **Leg 0**, alongside the other money holes, and the assertion is a
  controller test that POSTs a foreign slug to a mid-workflow step and reads the resulting
  `transfer_data[destination]`.

  **That helper takes a key *set*, not a key.** A round spent looking for siblings found two
  more, below, and the reason to write the fix as a set is that the next server-derived key
  someone adds to run data inherits the protection instead of inheriting the bug. The set
  Leg 0 ships with is `__tenant_slug`, `user_id` and `payment_id`; the rule is that a key
  the server derives is re-derived by the server on every step and a client value for it is
  refused, not merged.

  *The webhook side of this was reviewed and is clean.* `Webhooks.pm:106` resolves the tenant
  from `metadata.tenant_slug` rather than `event.account`, which reads like the same trust
  bug and is not: `STRIPE_WEBHOOK_SECRET` is mandatory and unsigned bodies are rejected
  (`:11-26`), the metadata is Registry's own snapshot echoed back, and `event.account` is
  genuinely absent on destination-charge payment_intent events because those are platform
  events — which the comment at `:103-105` already says. It inherits this bug's blast radius
  and has none of its own.
- **The same channel carries a SQL operator, and one POST field wipes a tenant's ledger.**
  This is the worst thing in the money path and it is a strictly larger bug than the one
  above, because it needs no knowledge of any id. `WorkflowStep::expand_form_params`
  (`WorkflowStep.pm:122-144`) re-nests Rails-style bracketed parameter names into hashrefs,
  and `_arrayify_numeric_hashes` (`:148-159`) leaves a sub-hash alone unless every key is an
  integer. So `payment_id[!=]=00000000-0000-0000-0000-000000000000` arrives in run data as
  `{ payment_id => { '!=' => '00000000-…' } }` — a **SQL::Abstract operator hashref**, not a
  string — and rides the same passthrough-plus-jsonb-merge path as `__tenant_slug`.

  `WorkflowSteps/Payment.pm:146` then reads it and hands it to three queries **unsanitized,
  as the whole WHERE clause**:

  ```
  :153  Payment->find($db, { id => $existing_payment_id })      -> SELECT … WHERE id != ?
  :165  $raw_db->update('payments', {...}, { id => $existing_payment_id })
                                                                -> UPDATE payments SET
                                                                     amount_cents = ?,
                                                                     metadata = ?
                                                                   WHERE id != ?
  :167  $raw_db->delete('payment_items', { payment_id => $existing_payment_id })
                                                                -> DELETE FROM payment_items
                                                                   WHERE payment_id != ?
  ```

  Those three renderings are not inferred; they were produced by running the project's own
  `SQL::Abstract::Pg` against that hashref. The status guard at `:154` does not help — it
  inspects the single row `find` returned (the newest row that is not the all-zeros UUID,
  because `Object.pm:14` orders `-desc created_at`), while the UPDATE and DELETE below it
  operate on every *other* row. So: every payment row in the tenant schema is overwritten
  with the attacker's cart total and the attacker's `enrollment_items` metadata — completed
  and refunded rows included — and the line items of all of them are deleted. The attack is
  deterministic: submit the payment step once normally so your own `pending` row is the
  newest, then re-post an earlier passthrough step with the bracketed parameter and submit
  again.

  This is not a variant of the previous bullet and the previous bullet's fix does not close
  it. Re-deriving `__tenant_slug` server-side leaves `payment_id` untouched, and even a
  server-owned key set only closes it by refusing a client `payment_id` outright. **Leg 0
  needs both halves**: the key set, and a type check at the point of use — a run-data value
  destined for a `WHERE` clause is a scalar or it is refused. The ownership check belongs
  here too: `create_payment` already stamps `workflow_run_id` into the payment's metadata at
  `:198` and never reads it back, so the reuse branch should require
  `$existing->metadata->{workflow_run_id} eq $run->id` before it touches the row. Assertion:
  POST `payment_id[!=]=<any uuid>` to `camper-info`, submit payment, and assert that a
  second family's payment row and its line items are byte-identical afterwards.
- **`user_id` has the same exposure, and the guard that was supposed to prevent it is what
  enables it.** `Workflows.pm:270` writes the session user into run data only
  `if ($current_user && !$run->data->{user_id})`. The comment above it at `:265-267` calls
  the `!$run->data->{user_id}` guard "safe: idempotent" — and idempotence is exactly the
  property that makes a value planted in the run-creating POST permanent, because the server
  then declines to correct it. `AccountCheck`'s `continue_logged_in` branch
  (`AccountCheck.pm:70-86`) confirms only that the user row *exists*; it never compares it to
  the session, and then advances the run. Downstream that value is the payment row's
  `user_id` (`WorkflowSteps/Payment.pm:193-194`), the Stripe `receipt_email` (`:224`), the
  `parent_id` on every enrollment (`DAO/Payment.pm:366`), and the family whose children
  `SelectChildren` lists and adds to (`SelectChildren.pm:14,56`).

  Honest scoping, because it differs from the two above: user ids are UUIDv4
  (`sql/deploy/users.sql:13`) and Registry never renders another family's, so the damaging
  variants need an id obtained out of band. What needs nothing is the gate itself — the
  routes at `Registry.pm:761-767` sit behind no auth bridge, so the account-check step can be
  satisfied with no session at all. That makes it a Leg 0 item on the strength of the gate,
  not the impersonation.
- **What gets priced and what gets enrolled are two different arrays, and a single POST can
  make them disagree.** The charge is computed from `children` × `session_selections`
  (`WorkflowSteps/Payment.pm:38-41`); the enrollment is created from `enrollment_items`
  (`DAO/Payment.pm:350-369`, `my $session_id = $item->{session_id} or next;`). Nothing
  reconciles them. They are written by one function in one `update_data` call
  (`MultiChildSessionSelection.pm:143-147`), which reads like an invariant and is not one,
  because the two sides come from different inputs: `@children` is resolved server-side from
  `selected_child_ids` (`:31-34`), while `%selections` accepts **any** form key matching
  `/^session_for_(.+)$/` and trusts the captured string as a child id (`:57-64`), with no
  check that it appears in `selected_child_ids`. `@enrollment_items` is then built from
  `keys %selections` and `@children_data` from `@children`.

  Every validation in that step — completeness (`:69-73`), capacity (`:93-100`) and age
  eligibility (`:103-112`) — iterates `@children` only. So an extra `session_for_<id>=<session>`
  pair is unpriced, uncapacity-checked, unage-checked, and enrolled. A parent pays for one
  child's cheap session and enrolls a second child in an expensive one.

  The spec never names `enrollment_items` (zero hits), which matters for **Leg 8**: as
  written, the `Quote` replaces the price side and `finalize_enrollment` keeps iterating the
  free-floating key. Leg 8's rewire is only complete if the quote carries the resolved
  (child, session) pairs and both `finalize_enrollment` and `Enrollment->enroll_children`
  read them off the quote, so the key dies with `calculate_enrollment_total`. Until then
  **Leg 0** adds the cross-check: `%selections` keys must be a subset of `selected_child_ids`,
  refuse otherwise.
- **A concurrent signup changes what the current one is charged.**
  `WorkflowSteps/TenantPayment.pm:104-107` ignores the run it was handed and re-resolves one:
  `my $run = $workflow->latest_run($db)`. `latest_run` is `Workflow.pm:76-79` → the DAO base
  `find` with the default order `{ -desc => 'created_at' }` (`Object.pm:14`), so it returns the
  newest run of the tenant-signup workflow *on the whole platform*, not this visitor's. The
  method then reads `selected_pricing_plan` off that stranger's run (`:111-112`) and falls back
  to the platform Free plan when it is absent (`:118-138`).

  This is a display bug at `:85` and a money bug at `:339`, where the same call feeds
  `create_subscription_with_config` — the Stripe subscription is created against whatever plan
  the most recent signup selected. Two prospects overlapping by minutes is enough; the second
  one's Studio selection bills the first at Studio, or the first one's Free selection bills the
  second at nothing. It has been latent because signups have been serial.

  `get_subscription_config` already runs inside a method holding `$run`. It takes `$run` as a
  parameter and the `latest_run` lookup is deleted. **Leg 0**, with the other money holes —
  and the same read wants checking anywhere else `latest_run` stands in for a run in hand.
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
  **It also sends no `Idempotency-Key`** — `grep -in idempotency lib/Registry/DAO/Subscription.pm`
  returns nothing — and that is the more expensive half. Every POST through
  `_stripe_request` creates a money-shaped object: `:59` a Customer, `:140` a **Subscription**,
  `:181` a SetupIntent. With no timeout and no key, a dropped connection on `:140` leaves
  Registry with no subscription id and Stripe with a live subscription; the tenant retries,
  a second subscription is created, and `:148` records exactly one `stripe_subscription_id` —
  so the first is invisible to us and still billing the tenant every month. This is the
  identical defect Leg 0 fixes on the *enrollment* path with
  `metadata[registry_idempotency_token]`, in the one Stripe client that file list omitted.
  Leg 0 covers all three clients or the guarantee it is named for is not a guarantee.
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
  payment row. An earlier draft said the handler within it retrieves the intent from Stripe;
  it does not — `Webhooks.pm:98` reads `$event->{data}{object}` out of the signed payload and
  the enrollment path makes no Stripe call at all. The one blocking call that really is inside
  the transaction is `Subscription::get_subscription`, reached from `:319` and `:332`, and it
  runs on the bare user agent built at `Subscription.pm:16-19` — the one with no request
  timeout, which is why Leg 0 gives it one. Untimed is not unbounded: `Mojo::UserAgent`'s
  40-second inactivity timeout kills a stalled stream, so the ceiling is tens of seconds rather
  than forever. That is still a payment row locked across a network round trip with Stripe's
  own retry queued behind it. Neither is a correctness problem — that is what the lock is for —
  but it is a throughput ceiling worth writing down rather than discovering under load: **the
  transaction does the minimum Stripe work, and anything that can be done before `begin` is.**
  For the subscription path that means resolving the subscription before opening the
  transaction, which costs nothing and is easy to write the other way round by accident.
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

  **Under Accounts v2 there is no revoke endpoint, and the design is better for it.**
  `/v1/oauth/deauthorize` is an OAuth mechanism and OAuth is on Stripe's list of cases where
  *"You must use Accounts v1"*. The other candidate does not work either: `/v2/core/accounts/
  {id}/close` returns `stripe_loss_liable_cannot_be_deleted` — *"Account with Stripe-owned
  loss liability and dashboard cannot be deleted"* — which is precisely the configuration
  chosen above. So Registry cannot revoke, close, or delete a tenant's account.
  `account.application.deauthorized` **does** survive, gated on Dashboard access rather than on
  OAuth; see "`account.application.deauthorized` survives" above for the two citations. It is a
  reconciliation backstop here, not the mechanism — the fee still has to be cleared before the
  tenant leaves, and this event says they already have.

  That is the correct outcome rather than a missing feature. With `losses_collector: stripe`
  and `dashboard: full`, the account is the tenant's property and their relationship with
  Stripe; Registry is a platform they granted access to, not the owner of their merchant
  identity. Disconnect is therefore entirely a Registry-side operation, and it is the same
  list of work minus the last step:

  **Registry-initiated** is a "disconnect from Registry" action with four steps: (1) end the
  tenant's schedule rows, (2) clear `application_fee_percent` from every subscription Registry
  created on that account, (3) stop the charge path from resolving that tenant, and (4) clear
  `stripe_connect_account_id`. The ordering argument in the earlier draft — clear the fees
  *before* revoking — evaporates along with the revoke call, but clearing the fees does not:
  a subscription left with `application_fee_percent` set keeps paying Registry after the
  relationship ends, and nothing external stops it.

  **The four steps do not all fit in Leg 3, and two of them cannot.** `pricing_schedules` does
  not exist until Leg 7, so step 1 has no table; Registry creates no subscription carrying
  `application_fee_percent` until Leg 8's `PriceOps::Schedule`, so step 2 has nothing to
  clear. Leg 3 depends on 0, 1 and 3a only. So **Leg 3 ships steps 3 and 4** — which are the
  two that matter on Leg 3's own deadline, because they are what stops a charge going to an
  account we should not be charging on — and **steps 1 and 2 land in Leg 8**, in the same leg
  that first creates the objects they operate on. Splitting it this way is not a compromise:
  between Legs 3 and 8 there are no schedule rows and no Registry-created subscriptions, so
  the two deferred steps have nothing to do in that window even if they existed. Leg 8's
  version of the action is the complete one, and the operator-facing runbook documents the
  four-step form.

  **Account-initiated has an event after all, and it is a backstop rather than a mechanism.**
  An earlier draft said "with OAuth gone there is no `account.application.deauthorized` to
  hook." That is wrong — Stripe gates the event on Dashboard access, not on OAuth, and
  `dashboard: full` meets the condition; see "`account.application.deauthorized` survives"
  above. What remains open is only whether a full-dashboard v2 account offers the tenant a
  "remove this platform" affordance in the first place, which the reference does not state and
  Leg 3a's spike answers. Either way the handler is small and its job is narrow: by the time
  the event arrives the tenant has already gone, and clearing `application_fee_percent`
  afterwards is a courtesy rather than a control — Stripe is explicit that the fee *"continues
  to be collected by the platform after disconnect."* So the handler ends the tenant's
  schedule rows, marks their enrollments stale, attempts the fee removal, and alerts when it
  cannot; it does not replace the Registry-initiated path, which is the only one that runs
  *before* the disconnect. **Do not build the account-initiated case into a mechanism the
  Registry-initiated one depends on.** What survives either way is the obligation: tell the
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
- **Nothing on the money path logs anything.** `grep -c 'log->'` returns 0 for
  `DAO/Payment.pm`, `Service/Stripe.pm` **and `DAO/Subscription.pm`** — three modules, not
  two. No request is logged, no response, and Stripe's `request_id` — the identifier their
  support asks for first — is captured nowhere. Two `->catch(sub {})` blocks swallow errors
  silently, and `Subscription.pm:96` degrades a failed charge to `warn`. This is tolerable
  while nobody is paying; it is not tolerable the first time a parent's money goes somewhere
  unexpected and the only record is what Stripe's dashboard chooses to show. Leg 0 adds
  structured logging to all three, keyed on `request_id`, because Leg 0 is where the money
  path stops being best-effort. `DAO/Subscription.pm` is the third file for the reasons given
  under "Registry→tenant billing failures" below, and counting it matters for sequencing as
  well as cost: it is Leg 3a's file too, so Leg 0 writes the header hash and Leg 3a adds
  `Stripe-Version` to it rather than inventing a second one.
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
  event delivered `200`. **Three of the five die with Leg 1's installment deletion, not two:**
  `Webhooks.pm:213` sits inside `_is_installment_payment_event` (`:204-227`), which resolves a
  `Registry::DAO::PaymentSchedule` against a table Leg 1 drops, so it goes with the rest of the
  installment machinery. The other two — `Subscription.pm:316,329` — are rewritten in
  **Leg 3a**, in the same commit as the version bump, because a bump
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
  this design explicitly supports. The quote knows the currency; Leg 9a is where it reaches
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
3. **The `charge.dispute.created` alert — the notification only.** Recording and notifying
   are two things and they belong to different legs. **Leg 3 records**: it registers the
   Connect endpoint and writes the dispute reference against the payment row, because the
   handler has to exist the moment real charges start or the first dispute leaves no trace.
   **Leg 12 notifies**: it sends the tenant the deadline and links them to the page pieces 1
   and 2 build, because a notification pointing at a page that does not exist is worse than
   silence. So the Leg 3 row says "dispute-*recording* handlers" and means it; this piece is
   the alert layered on top of a handler that already runs.

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
and `Family::sibling_discount_eligible`. All of these are **Leg 1**, with the rest of the safe
deletions.

`Family::sibling_discount_eligible` (`Family.pm:68`) belongs in Leg 1 rather than with the
model work because it has **no caller in `lib/`** — its only two callers are
`t/dao/family.t:237,249`, re-cut in the same commit. The sibling *calculation* it reads as a
precondition lives in `PriceOps/PricingPlan.pm:109-114`, which Leg 1 deletes anyway, so the
predicate and the arithmetic go together and neither outlives the other by a leg. This is the
mechanical half of the sibling-pricing loss recorded under "What gets deleted" above; the
substantive half — that `tiered` is the kind that would restore it, and `tiered` is out of
scope — is unchanged by which leg removes the dead predicate.

`PriceOps/PricingPlan.pm` goes in Leg 1. It is not dead — it is a discount calculator that
branches on `plan_type` at `:99,110,129,171` for `early_bird` and `family`, a vocabulary
this design replaces with components. Deleting it early is safe only because the discount
form it serves is deleted in the same leg; if that ordering slips, they slip together.

**And it has two compile-time callers in `t/`, one of which is not an installment test.**
`t/unit/installment-breakdown.t:11` and `t/dao/pricing-plan-amount-cents.t:11` both
`use Registry::PriceOps::PricingPlan`, so deleting the module does not fail an assertion, it
fails the file at load. The first goes with the installments. The second does not: it is the
cents-migration regression suite, and only its `'a dollar-denominated discount is scaled
before it meets a cents price'` subtest (`:146-166`) touches the deleted module — the rest
tests `DAO::PricingPlan` and must survive. Leg 1 drops that subtest and the `use` line and
keeps the file. This is the same stranded-caller shape as (34) and (38) in a third location:
**a `use` in `t/` is as load-bearing as a `use` in `lib/`**, and the whole file is the blast
radius rather than the line.

**That sweep was run for Leg 1 and for no leg after it, and two later legs delete modules with
live compile-time callers in `t/`.** The rule was stated and then applied once. Naming the
files:

- **Leg 7** deletes `PriceOps::PricingRelationships` and `DAO::PricingRelationshipEvent`.
  `t/dao/pricing-relationships-integration.t:17-18` `use`s both;
  `t/dao/pricing-relationship-events.t:17` `use`s the second and then exercises the dropped
  table end to end through it (`:80` `record_activation`, `:92` `record_suspension`, `:109`
  `find_by_relationship`, `:128` `get_latest_for_relationship`, `:147` `record_plan_change`,
  `:164` `get_audit_trail`). Both `plan skip_all` calls in those files are inside subtests, so
  a runtime skip cannot save either one. Both files are deleted in the same commit as the
  modules and the `DROP TABLE`; they test objects that no longer exist, so there is nothing to
  port.
- **Leg 9a** deletes `DAO::PricingRelationship`. Five more files break with it, and they do
  not all get the same treatment. `t/dao/pricing-relationship.t:15` is a dedicated test of the
  class — 13 references in 336 lines — and is deleted with it. The other four use the class as
  a *fixture* for something else and have to be rewritten onto the schedule the tenant now
  gets, not deleted: `t/dao/pricing-plan-selection-workflow-step.t:11` (4 references),
  `t/controller/tenant-pricing-display.t:18` (4),
  `t/dao/tenant-signup-pricing-integration.t:11` (2) — those three break at compile time — and
  `t/controller/tenant-create-session.t:35` (1), which calls
  `Registry::DAO::PricingRelationship->create` with **no `use` line at all** and survives today
  only on transitive loading, so it fails at runtime rather than at load, which is the harder
  failure to attribute. `t/dao/pricing-plan-clean-architecture.t:16` is a sixth reader and
  needs no action: Leg 1 already deletes the file (#296).

Neither list is expensive — three file deletions and five rewrites, inside legs already
costed 3-4 and 4-5. They are written down because
the cost of missing them is not the fix, it is a leg that leaves `prove -lr t/` red at its own
boundary under a stated 100%-pass gate, discovered by whoever runs the suite rather than by
whoever planned the leg. **The general rule, which is the part worth carrying into
`writing-plans`: a leg that deletes a module greps `t/` for its name, not just `lib/`.**

`PriceOps/UnifiedPricingEngine.pm` and `PriceOps/PricingRelationships.pm` are deleted **in
Leg 7, not before** — they are the only code in `lib/` that can write a
`pricing_relationships` row, so they must be replaced rather than removed ahead of the
replacement. `DAO::PricingRelationshipEvent` and the `registry.pricing_relationship_events`
table die with them. Close #76.

**`DAO::PricingRelationship` does not, and an earlier draft had it deleted in Leg 7 with the
other two.** That would break tenant signup for a full leg. `PricingPlanSelection.pm:10` is a
compile-time `use Registry::DAO::PricingRelationship;` — not a `require` — so deleting the
module does not produce a quiet `undef` from a query, it produces
`Can't locate Registry/DAO/PricingRelationship.pm in @INC` when the step class loads. The step
is slug `pricing`, **step 4 of 7 on `workflows/tenant-signup.yml`**, and it reaches the class
three times (`:84-87` and `:139-143` call `->find`, `:91` calls `->get_pricing_plan`). The
window would open at Leg 7 and close at Leg 8: no new tenant can sign up for a leg, and the
failure is a 500 rather than a degraded page.

**The template that step renders is owned by no leg, and it reads the column Leg 9b drops.**
`templates/tenant-signup/pricing.html.ep` reads `$plan->{pricing_configuration}` at
`:51,52,65,67,71,74,80,82` — description, `revenue_share_percent`, `trial_days`, `features` —
plus `amount_cents` at `:57` and `formatted_price` at `:61`, all of them keys
`PricingPlanSelection.pm:102-104` builds from a `DAO::PricingPlan`. Leg 8 repoints that step at
`Model->offered_versions`, which returns versions and components, not a plan row with a JSON
blob; Leg 9b then drops `pricing_configuration` outright. So the template is a reader of both,
and it appears in no row of the leg table. **Leg 8 owns it**, in the same commit that repoints
its step — a repointed step rendering a template that dereferences a key nothing supplies any
more is the signup menu going blank, which is the one page a prospective tenant sees. What the
template needs from a version is the same information under different names, so this is a
rewrite of eight expressions rather than a redesign; naming it is the point, not sizing it.

The generalization is the one this milestone keeps re-learning: **the caller names the class,
not the table, so retaining the table protects nothing.** Retention has to follow the artifact
the live reader actually touches. So the class and the table are retained together —
`DAO::PricingRelationship` stays until Leg 8 repoints
`PricingPlanSelection` onto `PriceOps::Model`, and both the class and the `DROP TABLE` land in
**Leg 9b**, one leg after the last reader moves. Nothing writes the table after Leg 7; the
retention is purely for the read.

An earlier draft called the class "unused elsewhere" and that is false at HEAD:
`BillingPeriod.pm:125-126` `require`s it, `PriceOps::PricingRelationships` uses it at
`:11,62,64,76,101,125`, and `UnifiedPricingEngine` at `:12,57,70,112,158`. The claim is true
only *after* Leg 7 runs, because Leg 7 deletes all three of those modules in the same commit —
which is a different statement and one an implementer needs, since deleting them in a different
order leaves live `require`s pointing at a file that is gone. Leg 7 deletes the three users
first and retains the class; Leg 9b removes the class once `PricingPlanSelection` no longer
names it.

`registry.billing_periods` and `DAO::BillingPeriod` are dropped in the same migration, and
the reason is a foreign key rather than a preference:
`billing_periods.pricing_relationship_id` references `registry.pricing_relationships(id)`
(`sql/test-schema.sql:4431`). Dropping `pricing_relationships` without dropping
`billing_periods` first fails, so the two go together — which is why the table drop moving
to Leg 9b takes `billing_periods` with it. `DAO::BillingPeriod` itself is dead and can go in
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
roughly four times Leg 10 and that Legs 3a, 3, 4 and 8 are where the milestone lives; the
absolute count is the weaker claim. Ranges are wide where a leg's cost depends on how much of
the E2E suite has to be re-cut rather than extended. 3a is named alongside the other three
because it is no longer the cheap pin it started as: it carries a live-Stripe spike whose
answer can change Leg 3's configuration, and it is the only leg whose failure mode is
*silence* rather than an error.

**The Content column is a summary, not the issue text.** Each row is a leg's outcome in one
line; the files it touches are named in the body, not in the table. An earlier draft of this
paragraph promised a "Files line under each row" and there is none — the table has four
columns and always has. That gap is the largest single thing `superpowers:writing-plans` has to
close: a row copied into a GitHub issue without the body passages behind it is not executable,
and per-leg file manifests are a mechanical extraction from prose already in this document.
See (37).

| Leg | Content | Depends on | Sessions |
|---|---|---|---|
| 1 | Safe deletions: installments, `Client::Stripe`, `PriceOps/PricingPlan.pm`, `Family::sibling_discount_eligible`, misfiled tests, #296, discount form; **the `seti_test` signup bypass**; **retire the seeded Registry Plus hybrid plan** so nothing on the menu needs a kind this milestone does not build; **a sqitch change dropping `payment_schedules`/`scheduled_payments` from `registry` and every tenant schema**, with its verify and revert — a deployed change is retired by a new change, not by deleting a file — **and the four already-deployed verify scripts that name those tables, three of which fail hard**; **`t/dao/tenant-payment-schema-isolation.t`, which seeds both dropped tables at `:43,170-206` to test the schema-move guard and has to be rewritten or deleted in this commit**; **the revert-test harness** the whole milestone then uses, which belongs to the first leg to ship a migration and that is this one | — | 4-5 |
| 0 | The money path becomes atomic and observable: webhook atomicity in one transaction on one connection (**#247** is a prerequisite, not a follow-up); `update` → `save` via a mutating `mark_completed`; **`SELECT … FOR UPDATE` on the payment row so the #283 stale-intent guards hold under concurrency**; **capacity re-checked at capture, inside that same `FOR UPDATE` block, with the branch for "capacity is gone" written out** — a `waitlisted` enrollment and `status => 'refund_pending'` inside the transaction, the Stripe refund issued **after** COMMIT under `Idempotency-Key: refund:capacity:<payment_id>`, because a refund inside the transaction is not undone by the ROLLBACK this leg's correctness rests on and a redelivered webhook then refunds a partial twice; **an idempotency-key parameter on `Service::Stripe::create_refund`**, which has none today while `create_payment_intent_async` does; **structured logging in `DAO/Payment.pm`, `Service/Stripe.pm` and `DAO/Subscription.pm` keyed on Stripe's `request_id`**, and the two silent `->catch(sub {})` blocks closed; **`calculate_enrollment_total` refuses an undefined price instead of skipping the child**, which is the live free-enrollment path; **`metadata[registry_idempotency_token]` on every Stripe object Registry creates, in all three clients** — which cannot be backfilled later — **plus a request timeout on `Subscription.pm`'s bare user agent**; **a unique index on `payments.stripe_payment_intent_id` and the status-aware replacement for `enrollments_session_student_type_unique`, both written with the per-tenant loop — and both resolved out of `pg_index`/`pg_constraint` by table and column set rather than by name, because `clone_schema` builds tenant tables with `LIKE … INCLUDING ALL` and Postgres regenerates index and unique-constraint names to its defaults, so the tenant copy of that constraint is called something else**; **rewrite the payment-row reuse guard at `WorkflowSteps/Payment.pm:152-154`** — the status test becomes an allow-list of `pending`/`processing` so re-enrolling after a refund cannot drive the refunded row back to `completed`, the run-data `payment_id` is refused unless it is a plain scalar, and the row is reused only when `$existing->metadata->{workflow_run_id}` equals `$run->id`, a linkage `create_payment` already writes at `:198` and has never read back; **`DAO::Subscription`'s tenant write joins the same transaction as the Stripe create, reads `trial_end` defensively, and cancels a subscription whose id it cannot record** — today a Solo signup dies in `DateTime->from_epoch` and leaves a live subscription Registry cannot see; **the server-owned run-data keys become unwritable by the client** — one helper re-derives `__tenant_slug`, `user_id` and `payment_id` on every step rather than only in `new_run` (`Workflows.pm:52-58` vs `:351`), because today a POST parameter on any passthrough step picks the Stripe destination account, `on_behalf_of` and the fee rate, and `Workflows.pm:270`'s `!$run->data->{user_id}` guard makes a planted identity permanent by declining to correct it; **a run-data value bound for a `WHERE` clause must be a scalar** — `expand_form_params` turns `payment_id[!=]=…` into a SQL::Abstract operator hashref that reaches `WorkflowSteps/Payment.pm:165,167` as the entire WHERE clause and rewrites or empties every *other* payment row in the tenant; **`MultiChildSessionSelection` requires `%selections` keys to be a subset of `selected_child_ids`** (`:57-64` trusts any `session_for_<id>` parameter, and the capacity and age checks at `:93-112` iterate the other array); **`TenantPayment::get_subscription_config` takes the run it is already holding instead of calling `$workflow->latest_run($db)`**, which returns the newest signup run on the platform and bills this visitor on a stranger's plan selection | 1 | 9-11 |
| 2 | **#294**: collapse `registry-platform` into `registry`; retire the all-zeros UUID as a provider identity, in `lib/` **and 21 test files including `t/lib/Test/Registry/Helpers.pm`**. The data migration's column surface is exactly `registry.tenants` (the row), `tenant_users.tenant_id`, `tenant_profiles.tenant_id` and `pricing_relationships.provider_id` (3 rows); `message_templates.created_by` (3 rows) is left alone. Resolve the `registry` tenant by slug — it is created by `sql/deploy/tenant-on-boarding.sql:23-28`, so it always exists. **`message_templates.created_by` is left alone deliberately: the same literal is doing duty as a system-user sentinel there, and repointing it at a tenant id would be silently meaningless.** **Supersede the two deployed verify scripts that read the literal** — five line-hits across `create-default-pricing-relationships.sql` (`:9-10`, `:13-16`, `:19-26`, whose fail-on-zero-rows idiom becomes a division by zero the moment the row is gone) and `unified-pricing-infrastructure.sql:47-49` (vacuous rather than red); `pricing-relationship-events.sql:25` was counted here in an earlier draft and is not a hit — that literal is a probe argument to a function | 1 | 3-4 |
| 3a | **Pin `Stripe-Version` to `2026-07-29.dahlia`** — off `2024-12-18.acacia`, across *three* release trains; it is a GA version on the dahlia train, the one Stripe's own v2 Accounts and event-destination docs send, and **not** a preview channel, which an earlier round asserted and this one disproved — in `Service::Stripe.pm:15`, `t/stripe-live/service-version.t` and `DAO::Subscription.pm:71-103` (which sends none); **keep Stripe.js on the evergreen `js.stripe.com/v3`**, which is not deprecated and whose six dahlia breaking changes all miss Registry's client surface; **rewrite the two surviving `invoice.subscription` readers the `2025-03-31.basil` release breaks** — `Subscription.pm:316,329`, each followed by a `return unless`, so the bump silently stops every invoice handler (the other three, including `Webhooks.pm:213` inside `_is_installment_payment_event`, die with Leg 1); **spike a chargeable full-dashboard v2 account in test mode**, with the exit criteria and decision owner named below; **make the acceptance gate capable of failing, in three ordered steps** — the repository has *no* Actions secrets (`gh api …/actions/secrets` returns `total_count: 0`), so `t/stripe-live/` skips itself and `stripe-e2e.yml` exits `NOTESTS` green: **perigrin provisions the three secrets** (`sk_test_`, `pk_test_`, webhook signing secret), **then a fail-fast step asserts `STRIPE_SECRET_KEY` begins with `sk_test_` before `prove` runs**, and only then does `continue-on-error` come off `stripe-e2e.yml` and `main` get branch protection — removing it first changes nothing, because the masked steps are genuine passes; **and correct `.github/workflows/ci.yml:128`**, whose "Real keys live in the stripe-e2e workflow" comment is false and is the likeliest source of this document's own earlier assumption | 1 | 4-6 |
| 3 | Charge model: **Accounts v2 (`losses`/`fees` = `stripe`, `dashboard` = `full`)**; `Service::Stripe` gains a JSON `/v2/` branch; tenant→family becomes direct charges; `Stripe-Account` in `Service::Stripe` (refusing, not falling back); refunds lose `reverse_transfer` and gain an idempotency key; **the refund path is made reachable at all** — `ValidateDropRequest` propagates `refund_requested`, `_process_immediate_drop` (defined at `:263`, called at `:259`) takes the refund flag instead of hardcoding `'none'`, `Payment::refund` accounts partials against a running total **and caps at `amount_cents - sum(prior refunds)`**, its **idempotency key is derived from the `drop_request_id` rather than from payment-id-plus-amount, which two children at the same price collide on**, and `Job::ProcessRefunds` claims the rows that then exist; **a second migration widening `enrollments_refund_status_check`** (`sql/test-schema.sql:838`), which allows only `none`/`pending`/`approved`/`processed`/`denied` and would raise inside the Minion job *after* Stripe refunded; **the drop-approval route moves under an `admin`-only `under`** — `Registry.pm:678-680,690` currently lets any instructor approve a refund; `charge.refunded` and dispute-*recording* handlers; multi-`v1` signature and multi-secret; `account.updated` ordering guard; **`payments.stripe_account_id`**; Payment Element `stripeAccount`; **two webhook endpoints — Connect for v1 events *and* the family v2 `account.*` events, platform for `v2.core.account.*` thin events — and their secrets**; **a tenant `SELECT` by `stripe_connect_account_id`**; **a separate parse path for v2 thin events, which carry `related_object` and no `data.object`**; `application_fee.created`/`.refunded` subscribed; **set the launch revenue-share rate — a business decision perigrin has not made, filed as its own blocking task inside this leg rather than as a line in a row**, and it shares this leg's deadline; **the rate is a literal in three places outside `templates/` and changing it without them fails the deploy** — `bin/post-deploy-smoke-test.sh:61` greps the live landing page for `2.5%` and its failure kills the server so Render rolls back (`docker-entrypoint.sh:63-71`), `t/playwright/deploy-validation.spec.js:54` asserts the same string under `.github/workflows/deploy-validation.yml:57`, and `t/playwright/jordan-landing-journey.spec.js:96` asserts `2.5% revenue share`; **Connect onboarding creates the account Leg 6 publishes onto**; Registry-initiated disconnect **steps 3 and 4 only** (1 and 2 need tables from Legs 7 and 8); **rewrite `docs/operations/sacp-stripe-connect-onboarding.md`**; **fix the recurring scheduler, because `ProcessRefunds` is a poller and nothing in the repository can re-enqueue it** — the Render cron has failed every run across its whole log-retention window on a missing `MOJO_SECRET` (`render.yaml:96-110` omits the `fromService` block the worker has at `:87-91`; `Registry.pm:36` dies), `./registry job <task>` is not a resolvable command (Minion's is `./registry minion job -e <task>`), and `setup_recurring_jobs` (`Registry.pm:830-898`, called once from `:479`) never re-arms; plus one test asserting every task name enqueued anywhere in `lib/` or `docker-entrypoint.sh` exists in the `add_task` registry | 0, 1, 3a | 10-13 |
| 4 | `pricing_plan_versions` / `pricing_components` + immutability triggers; `pricing_plans` gains `provider_id` and `audience`, keeps `session_id`; **new `clone_schema` sqitch change with the skip list in every table-shaped loop**; normalize the two tenant table shapes, then migrate registry **and every tenant schema's** plans to v1, **taking a component's `amount_cents` from `pricing_plans.amount_cents` and never from the dollar-valued `pricing_configuration` keys**, which are stale and whose names mean cents in the code; **repoint the writer *and every reader* in one commit** — `PricingPlan->create` (which also becomes a thin wrapper over `publish_version`, so a post-Leg-4 plan has a v1 child and Leg 8 can resolve it), `find`, `find_by_id`, `get_pricing_plans`, `ProgramListing.pm:102` and `ProgramSetupOverview.pm:35`, the last gaining `provider_id = ?` it never needed as a private table; `plan_scope`/`plan_type`/`pricing_configuration` kept nullable and dual-written by `PriceOps::Model->publish_version`; **the per-kind publish CHECK** (`stripe_price_id` required for `fixed`, NULL for `percentage`) **and a CHECK constraining a `percentage` component's fraction to four decimal places**, because Stripe's `application_fee_percent` takes two decimals of a percent and anything finer is silently rounded at charge time; **the storefront stops being a second pricing engine** — `ProgramListing.pm:149-154`'s `min(amount_cents)` over unfiltered rows is deleted, not repointed, and the listing reads the same resolver the checkout does; **refuse to migrate a plan carrying sibling terms**; every column addition loops over **every tenant schema**, not just `registry` | 2 | 8-10 |
| 5a | **Decide the `pricing-plan-creation` fork** against the criterion below. **The output artifact is named: a decision entry appended to this document's decision log, and Leg 5's issue body rewritten to the single branch that won** — a fork resolved only in conversation leaves Leg 5 unfileable, which is the whole reason 5a exists. A Leg 4 exit task | 4 | 1 |
| 5 | Execute the branch 5a chose: rewrite the `pricing-plan-creation` workflow and its templates onto the version/component vocabulary, **or delete it**. Either branch also closes the two entry points into it (`ProgramSetupOverview.pm:75`, `templates/pricing-plan-creation/complete.html.ep:51`) and the plan-creation call at `ReviewActivatePlan.pm:101-115` that passes **no `session_id`** | 5a | 1-4 |
| 6 | Publish projection: version → Stripe Product, component → Stripe Price **on the provider's account**; ids recorded; `published_at` written last; **backfill-publish every v1 migrated in Leg 4** on the predicate Leg 4's CHECK already states — **percentage-only versions unconditionally**, since they need no Price, and **versions carrying a `fixed` component only where the provider has a connected account**; the rest stay drafts and the leg `log`s the count rather than skipping silently; **every Stripe create in the backfill carries an idempotency key derived from the version and component ids**, because the backfill calls Stripe mid-migration and a re-run after a partial failure must not double-create Products and Prices; `Subscription.pm` stops building inline `price_data`, **and `handle_setup_completion` creates no Stripe Subscription at all when the published version has no recurring `fixed` component**, which is the Solo path | 3, 4 | 3-4 |
| 7 | `pricing_schedules` + **`CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public`** — the schema clause is load-bearing and production-only: without it the extension lands in `registry` under the majority `SET search_path` template, `clone_schema`'s unfiltered `pg_proc` loop re-declares its ~212 `LANGUAGE C` functions into every new tenant schema, and the non-superuser Render role gets `permission denied for language c`, so tenant onboarding stops in production while CI (superuser) stays green — + the overlap exclusion constraint; migrate `pricing_relationships` + `platform_pricing_plan_id` (**both kept and dual-written — the table *and its DAO class* have a live reader until Leg 8**), writing a schedule row for **every** tenant; delete `UnifiedPricingEngine`, `PriceOps::PricingRelationships`, `DAO::PricingRelationshipEvent` and `DAO::BillingPeriod` — **but not `DAO::PricingRelationship`**, which `PricingPlanSelection.pm:10` `use`s at compile time; **drop `registry.pricing_relationship_events` with all four objects that came with it** — the view `pricing_relationship_current_state` and the functions `get_next_aggregate_version`, `ensure_event_sequence` and `get_relationship_state_at` — **and supersede `sql/verify/pricing-relationship-events.sql`, which reads the table, the view and one function**; **delete `t/dao/pricing-relationships-integration.t` and `t/dao/pricing-relationship-events.t` in the same commit** — they `use` the deleted modules at compile time and exercise the dropped table through them, and their `plan skip_all` calls are inside subtests so a runtime skip cannot save either | 4 | 3-4 |
| 8 | `Entitlement` + `Quote` + `Model->offered_versions`; rewire the charge; **`Schedule` creates direct-charge subscriptions with `application_fee_percent` = the plan's fraction × 100** and an idempotency key; **the family Customer and payment method that subscription needs, which no leg previously owned** — a SetupIntent (or `setup_future_usage` on the enrollment intent) issued with `Stripe-Account`, the Customer created on the tenant's account, and a tenant-schema column holding one customer id per connected account; **an `invoice.paid` handler that writes the settled `payments` row**, without which Leg 13's replay assertion has nothing to count; **subscription envelope dispatch**; omit-never-zero `application_fee_amount`; repoint `PricingPlanSelection` **and `templates/tenant-signup/pricing.html.ep` with it, in the same commit** — the template reads `pricing_configuration`, `amount_cents` and `formatted_price` off a plan row that stops existing — **and the three readers of the `selected_pricing_plan` key that step writes** (`TenantPayment.pm:111-112` inside `get_subscription_config`, `TenantPayment.pm:429-430` which writes `platform_pricing_plan_id`, and `TenantSignupReview.pm:12`), none of which any earlier draft named; and `GenerateEvents`; delete `calculate_enrollment_total` and the `!$ENV{STRIPE_SECRET_KEY}` bypass; refuse-not-zero; **move the `stripe_connect_ready` gate into `prepare_payment_data`** — not `process`, whose own refusal re-enters the quote at `:136`, and not `_render_data`, which is one of the two callers rather than the chokepoint; `prepare_payment_data` (`:61`) is the single function both render paths reach (`_render_data:97-99`, `prepare_template_data:80-81`), and the two act paths (`:38`, `:113`) refuse loudly instead; **`Waitlist->accept_offer` (`:187-226`) quotes** rather than creating an enrollment with no payment row, which is today the automated way a paid spot is given away; `customer.subscription.updated`/`.deleted` handlers, because `dashboard: full` lets a tenant cancel a Registry-created subscription; **`proration_behavior: 'none'` passed on every mutating request**, since it is a request parameter and not a stored setting; `RevenueShare` becomes a wrapper; **disconnect steps 1 and 2**, whose objects first exist here | 6, 7 | 12-15 |
| 9a | Quote columns on `payments` incl. `refund_application_fee` **and the quote's currency, which no caller has ever passed**; `Payment` fields and `save` column list extended; fee recorded; `DAO/AdminDashboard.pm:36` corrected; **rewrite `t/lib/Test/Registry/Helpers.pm` against `Entitlement`** — this is the leg that breaks it, not 5 or 7; **add the Customer configuration to each tenant's `Account` and swap `customer` for `customer_account`** — reversible via `configuration.customer.applied: false`, so this is a decision that can be unwound, not a one-way door; **remove the second write and the last readers of everything 9b drops, and ship no `DROP`** — `TenantPayment.pm:429-430` (`platform_pricing_plan_id`), `Subscription.pm:62-64` (`tenants.stripe_customer_id`), `DAO::PricingRelationship` — **whose deletion breaks five test files**: `t/dao/pricing-relationship.t` is a dedicated test of the class and dies with it, while `t/dao/pricing-plan-selection-workflow-step.t:11`, `t/controller/tenant-pricing-display.t:18` and `t/dao/tenant-signup-pricing-integration.t:11` use it as a fixture and are rewritten onto the schedule, and `t/controller/tenant-create-session.t:35` calls the class with **no `use` line at all**, so it fails at runtime rather than at load; **`t/playwright/setup_payment_test_data.pl:87` selects on `plan_scope = 'tenant'`** and CI runs it. **Gate: the dual-write tests are deleted and the full suite plus `stripe-e2e` are green with the second write removed** | 8 | 4-5 |
| 9b | The drops, one deploy after 9a and not before, because `sqitch` is never reverted and the previous image is guaranteed to run against this schema: **the deprecated columns, `tenants.stripe_customer_id`, the tenant-schema `pricing_plans`, and `pricing_relationships` + `billing_periods`**; **supersede the nine deployed verify scripts that read the dropped columns and tables** — `sql/verify/stripe-subscription-integration.sql:9` is the one the follow-up list already knew about and is one of nine, and two of the nine (`create-default-pricing-relationships.sql`, `unified-pricing-infrastructure.sql`) were already superseded once in Leg 2 and need it again here for a different object. **Gate: 9a has been live through one full deploy cycle** | 9a | 1-2 |
| 10 | **Create `metering_events`** and the `Metering->record` API; **add `pricing_components.applies_to` with the event vocabulary this leg defines** as a metering-side label only — **resolution step 4 stays unfiltered, and this leg does not touch it**; instrument **enrollment created and payment captured only** — every other candidate event is a separate argument about what is monetizable and is not in this leg | 7, 8 | 2-3 |
| 11 | Pillar 5 **for the model only**: a `./registry pricing` command with `author`, `add-component`, `publish` and `show` subcommands (`Registry.pm:50` already registers the namespace); retire hand-typed SQL seeds. **The CHECK constraints are Leg 4's** — this leg adds none. The schedule and storefront change-classes are deferred — see "Out of scope" | 4, 5, 6 | 2-3 |
| 12 | Dispute resolution *surface* — **scope is an open perigrin decision between a list view plus deep link (2-3) and the embedded build costed here (3-5); see "Account configuration"**: admin page, embedded components, AccountSession, **and the `charge.dispute.created` tenant notification** on top of Leg 3's recording handler; `Job::ReconcilePayments` **plus the `Service::Stripe` search method it needs, which does not exist** — and it runs on the scheduler Leg 3 repairs, since a drift sweep has no triggering event and cannot be enqueued on demand; **widen the CSP at `Registry.pm:524,527`, which today allows only `js.stripe.com` and will block Connect's embedded components** | 0, 3, 9a | 3-5 |
| 13 | **The acceptance test**: `t/stripe-live/author-a-new-plan.t` — author, publish, enroll, charge, refund, on a live test-mode Connect account, asserting `livemode: false` on every object, **asserting the application fee the way Point 2 says it has to be asserted — off the `application_fee.created` event, with a bounded poll of `GET /v1/application_fees?charge=…` as the fallback, because `expand[]=application_fee` is not available on a PaymentIntent-created charge**, replaying a webhook against the unique index, and covering both the PaymentIntent and Subscription paths. **It authors its own fixtures end to end — including the `pricing_schedules` row that entitles its test tenant, which no earlier leg writes for a tenant created inside a test.** It lands last of all because it asserts against both the model (Leg 11) and the charge (Leg 8) | 8, 11, 12 | 1-2 |

**71 to 97 sessions** — a spread wide enough that any token figure derived from it is context
rather than a budget. Leg 5's floor moves from 0 to 1: even the delete branch has to close the
two entry points that would otherwise 404 and decide what replaces `ReviewActivatePlan`'s plan
creation, so zero was never a legal answer to a fork whose cheap branch is still a branch.

**The number has moved eight times — 31-46, 33-49, 32-51, 39-58, 57-81, 65-90, 66-91, now
71-97 — and the movement, not the number, is the finding.** Trace each move and none of them is a re-costing
of work already listed: 31-46 → 33-49 added Leg 3a; → 32-51 turned Leg 5 into a fork and added
Leg 12 scope; → 39-58 added seven sessions of newly-discovered scope; → 57-81 added a leg (13),
split another (5a), and raised Legs 0, 3, 3a, 4, 8, 10, 11 and 12 on work the rows had not
listed; → 65-90 added the stranded sqitch verify scripts, five money holes across Legs 0, 3, 4
and 8, and a revert harness that moved from Leg 0 to Leg 1; → 66-91 adds the one leg the verify
sweep had missed (Leg 7, which drops a table plus a view and three functions); → 71-97 raises
Leg 0 by two for the run-data trust boundary (a key *set*, a scalar-only `WHERE` rule, and two
constraints that have to be resolved by column set because `clone_schema` renames them), raises
Leg 8 by three for the family Customer and `invoice.paid` handler that recurring collection
needs and no leg owned, and splits Leg 9 into 9a and 9b because a `sqitch` schema is never
reverted while a Render image always is.
**Every rise is scope discovery, which means the estimate is not converged rather than merely
pessimistic.**

An earlier draft drew comfort from shape stability — "the same four legs hold the same share"
— and that comfort was misplaced. Shape stability is nearly free here: Legs 3a/3/4/8 hold
about half the total because they are where the code is, and new work keeps landing in them
*because* that is where the code is, so the ratio would hold no matter how much was added. A
stable ratio alongside a **14% rise in one round and 67% across two** (39 → 57 → 65 at the
floor) is not convergence; it is the same distribution over a larger number. An earlier draft
called that "a 46% rise across two rounds," which was one round's figure wearing two rounds'
label. The honest statement is that 71-97 is the
current floor of what is known, not an estimate that has stopped moving, and the number should
be re-read after Leg 3a's spike reports — because that spike is the one input that can change
Leg 3's configuration rather than merely its length.

**A previous draft claimed convergence and round 10 falsified it.** That draft read the rate of
rise as "falling steeply — 46%, then 14%, then 1.5% — which is the strongest evidence yet that
the discovery is slowing." The next round put the floor up 7.6% (66 → 71), so the sequence is
46%, 14%, 1.5%, 7.6%: not a decay, a low round followed by a high one. Two rounds is not a
trend, and reading one as a trend is exactly the error the "shape stability" paragraph above
already recorded once. What the low round actually showed is narrower and survives: round 9
added only one session, but the two findings it did not cost — an attacker-writable
`__tenant_slug` and a cross-run `get_subscription_config` — are both money-path defects that
eight prior rounds missed. Round 10 makes the same point at a price: its worst finding, a single
POST parameter that rewrites or empties every other payment row in the tenant, cost Leg 0 two
sessions. **Session count is not a proxy for how much is left to find** — a round can be cheap
and still be the round that finds the hole. Neither round found its defects by grepping for a
name; both found them by asking where a value comes from.

**Round 11 confirmed three findings and moved the number by zero, and that is stated rather
than left to be inferred from an unchanged figure.** All three are authoring traps rather than
scope: one word (`SCHEMA public`) on a `CREATE EXTENSION`, eight test files across two legs
that were already costed to touch their own subsystems, and three Actions secrets plus a
four-line fail-fast step. The zero is not evidence of convergence — round 9 was nearly free and
found the two worst defects to that point. It does mean the *kind* of thing being found has
changed: rounds 8 through 10 found work the legs did not contain, and round 11 found ways the
work already in them fails silently when performed. A cheap round is only good news if the next
round is also cheap for the same reason.

**Round 12 was, and for the same reason: two confirmed findings, twelve refuted, the number
still 71-97.** Both are the round-11 shape rather than new scope. One is this document
contradicting itself — (30) put a Stripe refund inside the transaction whose correctness rests
on ROLLBACK, which two other passages forbid — and the fix is an ordering change inside work
Leg 0 already carries. The other is a poller with no working scheduler, repaired by copying one
`fromService` block and correcting one command. Three rounds now (9, 11, 12) have cost between
zero and one session while finding a double refund, a production-only onboarding stop and a
dead drift detector, which is the strongest available statement of the same point: **cost is
not severity, and neither is a proxy for how much is left.** What has changed across 11 and 12
is that the findings are increasingly *about this document* — its own rules broken by its own
prose — rather than about code the document had not read. That is what running out of code to
find looks like, and it is not the same as being finished.

Legs 3a, 3, 4 and 8 are 34 to 44 of that, about half the milestone in four legs, and the
concentration is the
useful signal: they are the charge model, the model tables and the resolver, and each is
large because it touches code rather than because it adds a table. Leg 3 accumulated the
hardening items that stop being optional once the tenant holds the account; Leg 4 needs a new
`clone_schema` change, a shape normalization, a per-tenant column loop and a write cutover
rather than one migration; Leg 8 is where every read path moves at once.

**A leg is not an issue, and the four big ones need split points named before they are
filed.** A session is one context window; Legs 8, 3, 0 and 4 are costed at 12-15, 10-13, 9-11
and 8-10. Filing each as a single GitHub issue produces four issues that cannot be finished in
the session they are started in, which is the shape that ends with a branch open for a week
and a reviewer reading a thousand-line diff. The split points are visible in the rows and are
named here so `writing-plans` does not have to invent them:

- **Leg 0** splits at the transaction boundary: atomicity + `FOR UPDATE` + the two indexes
  (one issue), then logging + idempotency tokens + timeouts (a second), then the three
  money holes it owns — the reuse guard, the subscription write, the undefined price (a third),
  then the run-data trust boundary as a fourth: the server-owned key set, the scalar-only
  `WHERE` rule, and the `MultiChildSessionSelection` subset check. The fourth is separable
  because it is the only one that touches `WorkflowStep`/`Workflows` rather than the payment
  and webhook path, and it is the largest single addition this leg has taken.
- **Leg 3** splits three ways along its own dependencies: endpoints and secrets first, because
  the body already says the code is the easy half; then the charge model (v2 accounts, direct
  charges, `Stripe-Account`, `payments.stripe_account_id`, Payment Element); then the refund
  path and its constraint migration, which touch nothing the first two touch.
- **Leg 4** splits at the cutover: tables, triggers and CHECKs first; then the data migration
  across registry and every tenant schema; then the writer-and-reader repoint, which must stay
  one commit and is the part that cannot be split further.
- **Leg 8** splits by reader: the resolver itself (`Entitlement`, `Quote`, `offered_versions`);
  then the enrollment charge path; then the subscription path and `Schedule`, which now carries
  the family Customer, the SetupIntent and the `invoice.paid` handler and is the heaviest of
  the four; then the remaining callers — `PricingPlanSelection` and its template,
  `GenerateEvents`, the waitlist.

Each sub-issue is independently mergeable and leaves the tree green, which is the test that
distinguishes a split from a cut. Legs 3 and 8 additionally carry the half-deployed-state rule
above, so their sub-issues merge but deploy together.

**Leg 3a is a spike and a version bump, and it is deliberately in front of the deadline
leg.** Both halves are cheap to do early and expensive to discover late: a pinned API version
touches every Stripe call Registry makes, and the account-fixture question decides whether
the milestone's acceptance test can run at all.

**The spike has three questions, one deliverable, one owner and a named fallback**, because
"it is an argument to revisit `dashboard: full`" is a design decision wearing a spike's
clothes, and the decision has — in this document's own words — a company-shaped consequence.

This list has been stated three different ways in three different places in this document, and
this is the authoritative one. Two questions earlier drafts sent the spike after are answered
by the reference and are struck: whether `requirements_collector` can be chosen (it cannot —
Stripe derives it), and whether `losses_collector` is updatable after creation (it is not —
`defaults.responsibilities` cannot be updated at all). A third, whether
`account.application.deauthorized` survives, is also answered: it does.

1. Can a chargeable full-dashboard v2 account be provisioned unattended in test mode, and does
   `t/lib/Test/Registry/StripeConnect.pm`'s KYC path have a v2 equivalent?
2. Which endpoint receives `application_fee.created` for a direct charge on a connected
   account — Connect or platform? The reference does not say, and the acceptance test's fee
   assertion now depends on the answer; see "Point 2 is a race."
3. Does a full-dashboard v2 account give the tenant any "remove this platform" affordance at
   all? A "no" collapses the account-initiated disconnect case entirely.

**Deliverable:** a written answer to all three, in the Leg 3a PR description, with the
test-mode account id and the request/response for each. Not a verbal report.

**Fallback, named in advance so the spike does not become a debate — and it is not the one an
earlier draft named.** That draft said a "no" on (1) means Leg 3 ships `dashboard: none` plus
Stripe-hosted onboarding. That does not solve the problem it is a fallback for: the fixture
needs Registry to be the *requirements collector*, and per "Account configuration" above,
`dashboard: none` alone does not make it one. Only `losses_collector: application` does, and
that forces `fees_collector: application` — Registry taking negative-balance liability and
fronting Stripe's processing fees. Trading the whole fee model for a test fixture is not a
fallback, it is a different company.

So the real fallback is cheaper and duller: **the acceptance test's connected account is
provisioned once, by hand, in test mode, and the fixture reuses it by id from CI secrets.**
`t/lib/Test/Registry/StripeConnect.pm` stops creating an account per run and starts asserting
against a long-lived one. That keeps the gate runnable and unattended after a single manual
step, and it costs Leg 3a a fixture rewrite rather than costing the platform its economics.
**perigrin still makes the call on the spike's report** if the answer is stranger than either
option — it is the only decision in this milestone explicitly reserved — but `dashboard: full`
is no longer contingent on question (1).

A "no" on (1) arriving *before* Leg 3 costs a session. Arriving after it costs Leg 3 twice.

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

The legs at the bottom are cheaper because Legs 4 and 7 will already have built the tables
they stand on — that is the sequencing paying off, not those legs being unimportant. They are
not *cheap*, though, and an earlier draft's "`Metering` costs a single session" was an
estimate of the table rather than the leg. The table is a session; deciding which events are
monetizable and instrumenting them is the rest, which is why Leg 10 is scoped down to two
event types and costed at 2-3.

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
supersedes them until Leg 9b removes them — one migration later than feels tidy, which is
the correct trade when the alternative is an unpriced enrollment.

**`pricing_relationships` is the third column in that pattern and an earlier draft dropped it
in Leg 7 anyway.** The table is only *written* by dead code, which is what "What gets deleted"
argues from, but it is still *read* by live code: `PricingPlanSelection.pm:10` uses
`DAO::PricingRelationship`, `:84` and `:139` call `->find` on it, and that step is `pricing`,
step 4 of the 7 in `workflows/tenant-signup.yml` — the menu a new tenant picks a plan from.
Leg 8 is what repoints it, and it repoints it at **`Model->offered_versions`**, not at
`Entitlement`: the step renders a list of buyable plans, which is the one question a Quote
cannot answer. See "Which plans are offered, and to whom." So Leg 7 dropping the table opens a full leg in
which tenant signup dies at step 4, and it dies in the leg *after* the one whose migration
caused it, which is the worst possible place to debug it. The table follows the same rule as
the two columns: Leg 7 writes a `pricing_schedules` row for every relationship and leaves
`pricing_relationships` in place, Leg 8 moves the reader, Leg 9b drops the table. That drags
`billing_periods` to Leg 9b with it, since the FK at `sql/test-schema.sql:4431` is what forced
them into one migration.

**The *class* follows the table, not the modules, and an earlier draft split them the wrong
way.** "The dead modules still go in Leg 7, because deleting a writer nothing calls breaks
nothing" is true of `UnifiedPricingEngine`, `PriceOps::PricingRelationships`,
`DAO::PricingRelationshipEvent` and `DAO::BillingPeriod`. It is false of
`DAO::PricingRelationship`, which is not a writer and is not dead: `PricingPlanSelection.pm:10`
`use`s it at **compile time**, so deleting the file does not degrade the step, it prevents the
step class from loading at all — `Can't locate Registry/DAO/PricingRelationship.pm in @INC`,
a 500 on step 4 of signup, for the whole of Leg 7 and most of Leg 8. Retaining the table while
deleting the class protects the artifact the caller does not touch. So
`DAO::PricingRelationship` is retained alongside the table and both are removed in Leg 9b,
after Leg 8 moves the reader. The rule this is an instance of: **retention follows the name in
the caller.** Three of this milestone's stranded-caller defects have been a writer or an
artifact moving one leg ahead of its reader, and this one differed only in being a `use` line
rather than a table name.

**Leg 6 cannot publish for a tenant that has no Stripe account, and today that is every
tenant.** Publishing puts the Product and the Prices on *the provider's* account, so a
tenant's program plan needs `tenants.stripe_connect_account_id`. No row has one: no `acct_`
id appears anywhere in `sql/`, and the column is NULL throughout `sql/test-schema.sql`. Leg 6
backfill-publishes every v1 Leg 4 migrated, so run as written it either dies on the first
tenant plan or writes a `published_at` with no Stripe ids behind it — and the second outcome
is the dangerous one, because Leg 8 will then quote a version it cannot collect against.

**But "the provider has a Stripe account" is the wrong predicate, and using it strands
Registry's own revenue.** A `percentage` component has no `stripe_price_id` — the per-kind
CHECK in Leg 4 requires it to be NULL — because a revenue share is a parameter on somebody
else's charge, not a Price object. So a percentage-only version needs no Stripe account to
publish, and gating on the account leaves every one of them a draft. Registry's platform plan
is exactly such a version, and both seeded tenants (`sql/test-schema.sql:2512-2514`) have
`stripe_connect_account_id` NULL — including `registry` itself. Under the account predicate
the platform plan never publishes, Leg 8's `RevenueShare` wrapper finds no published version,
and it refuses on **every charge on the platform**, not on one tenant.

The right predicate is the one Leg 4's CHECK already states: **a version publishes when every
component that needs a Stripe Price can get one — that is, when the version has no `fixed`
component, or its provider has an account.** Percentage-only versions publish unconditionally.
Versions with a `fixed` component and no account stay drafts, and Leg 6 `log`s the count; a
tenant's fixed-price plans publish when that tenant connects, which is a step of onboarding
rather than a step of this migration. Registry's own platform plan is unaffected — but for
this reason, not because it has an account. It does not have one.

**And Leg 8's refusal arrives upstream of the friendly message that exists to catch it.**
`WorkflowSteps/Payment.pm:131` already handles an unconnected tenant well: it returns
*"Online payment is not yet available for this organization"* and keeps the parent in the
workflow. But it only runs after a total has been computed, and the calls that compute it are
ahead of it. Leg 8 replaces those calls with `Entitlement->quote`, whose entire contract is to
refuse when nothing resolves, so an unpublished plan on an unconnected tenant becomes an
exception and the parent gets a 500 where they used to get a sentence. This is the general
shape of the leg: a resolver that refuses is correct, and every caller that was written
against one that returned nothing has to be re-read before it gains a refusal.

**The gate goes in `prepare_payment_data`, and the previous two answers to this question were
both wrong.** The first draft put it in `process`. A review round moved it to `_render_data`
on the grounds that "most of those never pass through `process` at all: `:57` is the page
view" — and that sentence is the inversion of the code. `process` spans `:22-59`, so `:57` is
*inside* it, and every one of the nine `_render_data` call sites (`:57, 136, 229, 239, 277,
292, 309, 349, 362`) is in the `process` call tree. The conclusion was built on a call graph
read upside down and is corrected here rather than quietly replaced.

The real shape. There are **three** `calculate_enrollment_total` call sites — `:38` in
`process`, `:68` in `prepare_payment_data`, `:113` in `create_payment` — and exactly **two**
functions reach `:68`: `_render_data` (`:97-99`) and `prepare_template_data` (`:80-81`).
`prepare_template_data` is the one entry that does *not* route through `process`, which is
precisely why `_render_data` is not the chokepoint either. `prepare_payment_data` is: it is
the single function both render paths call, and it is one frame below both of them.

What was right in the earlier correction, and survives it: **the gate's own refusal re-enters
the quote.** `:131-137` returns `data => $self->_render_data($db, $run)` at `:136`, so a guard
in `process` that renders the friendly message calls the refusing resolver on the way out, and
the tenant the gate exists for is the one tenant guaranteed to hit it. That argument does not
depend on the call graph being inverted and it still rules `process` out.

So: `prepare_payment_data` returns a quote-less `step_data` carrying the "Online payment is not
yet available for this organization" state when the provider cannot be quoted, which covers
both render paths and makes `:136`'s re-entry harmless. `:38` and `:113` are the *act* paths —
they take money — and they refuse loudly rather than degrade. One branch in the shared
function plus a refusal on the two paths that move money, rather than a branch in every path.

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
*"This is a deployment bug"* (`:67-68`, `:123-124`). So from Leg 5 through Leg 9a, `publish_version`
writes the legacy `pricing_plans` row alongside the version, mapping `audience` back to
`plan_scope`. **An earlier draft closed the window in one step — "Leg 9 deletes the second
write and the columns in the same migration" — and that sentence is why Leg 9 is now two
legs.** 9a deletes the second write and ships no `DROP`; 9b drops the columns a deploy later.
The reasoning is under "A manual deploy controls when the schema moves, not whether it can move
back".

**The two windows do not open in the same leg, and an earlier draft opened both at 5.**
`plan_scope`'s window is Leg 5 to Leg 9a, because Leg 5 is what removes its writers.
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
milestone, but this milestone is what makes it expensive — seventeen legs, a dozen or more sqitch changes,
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
half-done. An earlier draft listed only the five with migrations, which is the wrong filter:
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

**A manual deploy controls when the schema moves, not whether it can move back, and this
design has no way to move it back.** `docker-entrypoint.sh:47` runs `deploy_schema` — plain
`sqitch deploy` (`:20-24`) — inside the new container *before* the daemon starts at `:50`,
while Render keeps the old instance serving until the new one answers `/health`
(`render.yaml:68`); the entrypoint then polls localhost for thirty seconds (`:55-61`) and runs
the smoke test (`:65-72`). So on **every** deploy of a drop-shaped leg there is a window,
thirty seconds and up, in which the previous release's code is live against the new schema.
If the deploy then fails, that state is where the system stays: the smoke-test failure kills
the server so Render reverts the *image*, and nothing anywhere reverts the *schema* —
`grep -rn "sqitch revert"` finds exactly one executable occurrence in the repo,
`.github/workflows/ci.yml:271`, which is CI.

Leg 9 is where that is fatal, and this document already said the dangerous half without
drawing the conclusion: "Leg 9 deletes the second write and the columns in the same
migration." Leg 8-era code writes `platform_pricing_plan_id`
(`WorkflowSteps/TenantPayment.pm:429-430`) and `tenants.stripe_customer_id`
(`Subscription.pm:62-64`) — and the second of those is the `UPDATE` that runs *after* a
successful `POST /v1/customers`, so the failure mode is a Stripe Customer that exists with no
local record of it, on the tenant-signup money path. The rollback does not even announce
itself: `bin/post-deploy-smoke-test.sh:8` points at `http://localhost` and its checks are
landing-page copy and step 1 of tenant signup, none of which touch the dropped columns, so
the previous image passes its own smoke test and comes up healthy and broken.

**So Leg 9 splits.** 9a removes the second write and the last readers and ships code only;
9b drops the columns and tables, one deploy later. And the general rule this leg is the first
to need becomes a gate on every leg that drops anything: *a leg is rollback-safe only if the
previous image runs correctly against this leg's schema.* Legs that only add are safe by
construction; legs that drop are safe only after a code-only predecessor has removed the last
writer.

The same rule covers the tenant-schema `pricing_plans` tables, and there the stakes are
higher because those rows are a tenant's actual program prices rather than a nullable
pointer. Leg 4 copies them up into `registry.pricing_plans` with `provider_id` set, repoints
the writer *and every reader* in the same commit, and leaves the originals in place —
**unread**. An earlier draft said they stayed "still read by `PricingPlan->get_pricing_plans`
through the tenant `search_path`", which is the split-cutover this design rejects at
"A write cutover with no reader cutover" above: it enrolls children free for four legs.
What the originals are after Leg 4 is a rollback target, not a live table. Only Leg 9b,
after `Entitlement` has been the sole read path for a leg, drops them. **The `clone_schema` exclusion moves to Leg 4** for the same reason in the other
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
on it. Legs 4 through 8 exist to give Leg 9a something true to write down.

**Leg 2 goes early for a data reason, and an earlier draft gave a code reason that runs
backwards.** That draft argued the all-zeros UUID appears in exactly five places in `lib/`,
every one of them in code this milestone already deletes or rewrites — `PricingRelationship.pm:140`
and `UnifiedPricingEngine.pm:26` die in Leg 7, `PricingPlanBasics.pm:70` and
`RequirementsRules.pm:186` are inside the authoring workflow Leg 5 rewrites, and
`PricingPlanSelection.pm:14` (the `PLATFORM_UUID` constant) is in the tenant-signup workflow
Leg 8 repoints — and concluded that collapsing early corrects them "once, as part of a rewrite
that was happening anyway." The premise is right and the conclusion inverts it. Leg 2 sits at
position 3 of seventeen; Legs 5, 7 and 8 are five, seven and eight legs later. Editing those five sites in Leg 2 and
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
twice over, but **both breaks land in the same leg**, which an earlier draft got wrong in
both halves. Leg 4 renames `plan_scope` to `audience` while keeping the old column nullable
and dual-written, and Leg 7 migrates `pricing_relationships` while keeping the table
dual-written; the helper survives both untouched. It is **Leg 9a** — the leg that stops the
second write and moves the last readers off both — that breaks it, and Leg 9a is where it is
rewritten against `Entitlement`. It is 9a and not 9b for the reason the split exists: the
helper breaks when the *writer* goes, not when the column does, and 9b only drops what nothing
has written for a deploy. Leg 2 does edit it, for the all-zeros constant, but that is
a one-line change and not the rewrite.

Two traps in that migration. The first is not the one an earlier draft named. That draft said
the `registry` tenant "is not created by any migration — it exists only in seed data", and so
the migration "must create it if absent". That is false: `sql/deploy/tenant-on-boarding.sql:23-28`
inserts `('Registry System', 'registry')` with `ON CONFLICT (slug) DO NOTHING`, and
`tenant-on-boarding` is the third change in `sql/sqitch.plan`, so on any deployed database the
row exists before anything in this milestone runs. `registry-platform` is likewise seeded by
`unified-pricing-infrastructure.sql:82` (`sql/test-schema.sql:2514`). Both targets are
migration-created. The migration still resolves them **by slug rather than by id** — the ids
are generated, so a literal UUID would be wrong on every database but the one it was written
against — but it resolves a row it is entitled to assume, and a `SELECT` that finds nothing
is a bug to raise on, not a row to create. And the
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

**Earlier drafts said "seven of the fourteen legs add a migration" and it was an undercount
twice over.** Counting the current table: Legs 0, 1, 2, 3, 4, 6, 7, 9a, 9b and 10 all change
`sql/deploy/`, and Legs 3, 4 and 7 need more than one change each — Leg 4 alone is the
version/component tables, the `pricing_plans` columns, the tenant-schema normalization and a
fresh `clone_schema`, and Leg 3 is `payments.stripe_account_id` plus the
`enrollments_refund_status_check` widening its refund vocabulary needs. Leg 1 joined the list when the installment deletion grew a migration:
`payment_schedules` and `scheduled_payments` are deployed tables, and a deployed change is
retired by a new change, not by deleting a file. Leg 9's two changes are no longer one leg's
problem: the additive half is 9a and the drops are 9b, deliberately a deploy apart. **Ten of
the seventeen legs add at least one migration, and the milestone is a dozen or more sqitch
changes.** The
number matters only because the per-migration obligations below are per-*change*, not
per-leg, and a leg that quietly contains three of them costs three times what the sentence
suggests.

**Each change also ships a verify script, and this is enforced already.** `sqitch.conf` sets
`[deploy] verify = true`, and `t/database/migration-verification.t:18-44` deploys the whole
plan to an ephemeral Postgres and runs `sqitch verify` over every change. All 64 deploys have
a matching verify today. So a leg that adds a migration and no verify does not merely skip a
nicety — it turns that test red, in a file whose name gives no hint that the pricing work
broke it. Write the verify with the deploy.

**And an old verify script is a live reader of everything a later change drops. This
milestone strands thirteen of them and the spec named one.** `t/database/migration-verification.t:24-27,62-64`
invokes `sqitch verify` with **no change argument**, which re-runs *every* deployed change's
verify script against the final schema. A verify written in 2025 that says
`SELECT … FROM registry.payment_schedules` is therefore an assertion this milestone has to
keep true, or delete, or rewrite — exactly like a caller in `lib/`. It is the same
stranded-caller defect as (34) with a different file extension, and **retention follows the
name in the caller** covers it verbatim.

Counted against the drops this milestone makes:

- **Leg 1** drops `payment_schedules`/`scheduled_payments`. Four verify scripts name them, and
  three fail hard rather than vacuously: `installment-payment-schedules.sql:13,21` selects from
  both tables, `simplify-installment-schema-for-stripe.sql:24` casts
  `'registry.payment_schedules'::regclass`, and `tenant-scoped-payments.sql:26-29`
  `RAISE EXCEPTION`s per tenant schema when the table is missing. `schedule-amounts-cents.sql:16-18,53`
  checks columns on them.
- **Leg 2** retires the all-zeros UUID tenant. `create-default-pricing-relationships.sql:9-10`
  is `SELECT 1/COUNT(*) FROM registry.tenants WHERE id = '000…'` — sqitch's fail-on-zero-rows
  idiom — so the collapse turns that verify into a division by zero. `:13-16` and `:19-26` use
  the same idiom against the same literal and fail the same way.
  `unified-pricing-infrastructure.sql:47-49` reads it too but as a plain `SELECT`, so it goes
  vacuous rather than red — still wrong, not still passing for the right reason.
  **`pricing-relationship-events.sql:25` is not a hit and an earlier draft counted it as one.**
  The literal there is `get_next_aggregate_version('00000000-…'::UUID)` — an arbitrary probe
  argument to a function, not a reference to the tenant row. Retiring the tenant does not touch
  it. It *is* stranded, by Leg 7, for a different reason; see below.
- **Leg 7** drops `registry.pricing_relationship_events`, and this leg was missing from the
  sweep entirely — the sweep was built from the two legs that drop columns and the one that
  drops the big tables, and Leg 7 drops a table without being either.
  `sql/verify/pricing-relationship-events.sql` reads it three ways: `:9-19` selects the eight
  columns, `:22` selects from the view `registry.pricing_relationship_current_state`, and
  `:25` calls `get_next_aggregate_version`. **The `DROP TABLE` also has three functions and a
  view to take with it** — `sql/deploy/pricing-relationship-events.sql` creates
  `get_next_aggregate_version` (`:41`), the `ensure_event_sequence` trigger function (`:56`),
  the view (`:88`) and `get_relationship_state_at` (`:115`). A bare `DROP TABLE` leaves the
  view broken and three functions orphaned; `CASCADE` takes the view and leaves the functions.
  Name all five objects.
- **Leg 9b** drops `plan_scope`/`plan_type`/`pricing_configuration`, `pricing_relationships`,
  `billing_periods`, `tenants.platform_pricing_plan_id` and `tenants.stripe_customer_id`.
  Nine verify scripts read those: `seed-free-platform-plan.sql:9-12`,
  `suspend-rateless-tenant-plans.sql:12-16`, `refund-application-fee-config.sql:10-23`,
  `create-default-pricing-relationships.sql:19-26`, `enhanced-pricing-model.sql:15`,
  `unified-pricing-infrastructure.sql:10-12,16-19,53-56`,
  `consolidate-pricing-relationships.sql:8-18`, `tenant-platform-pricing-plan.sql:11`, and
  `stripe-subscription-integration.sql:9` — the one the follow-up list already knew about.

That is **fourteen distinct files and sixteen per-leg obligations** —
`create-default-pricing-relationships.sql` and `unified-pricing-infrastructure.sql` are each
stranded twice, by Leg 2 and again by Leg 9b, and have to be superseded in both legs because the
first supersession does not know what the second one drops. So "check
`sql/verify/stripe-subscription-integration.sql:9`" understates the obligation by thirteen
files. The rule: **a leg that drops a database object greps `sql/verify/` for its name in the
same commit**, and supersedes each hit the way sqitch expects — a new change whose verify
asserts the new shape, with the old script edited to match the schema as of the end of the
plan. This is per-leg work, not a follow-up, and it is why Legs 1, 2, 7 and 9 are re-costed
below.

**Each change also gets a revert test, and there is no harness for one.** The rollback
subtest in that same file is `pass("Skipping rollback tests - focus on deploy and verify")`
(`t/database/migration-verification.t:46-49`) — a green assertion that asserts nothing, the
same shape as #296. So "every migration ships a tested revert" is not an instruction that can
be followed by adding a script; the first leg with a migration writes the harness: deploy to
the change, revert one, deploy again, compare the schema.

**That leg is 1, not 0, and an earlier draft said 0 "has a migration and is early, so it owns
it."** Leg 1 ships first — it is position 1 and Leg 0 is position 2 — and Leg 1 has a migration
of its own (the `payment_schedules` drop). A harness owned by the second leg to ship is a
harness the first leg's migration does not get tested by. Leg 1 owns it.

The harness also has to be *reachable* by the legs that must use it, and under Leg 0 it was
not. Legs 2, 4 and 7 all add migrations, and none of the three has a dependency path to Leg 0:
2 depends on 1, 4 on 2, 7 on 4. Three migration-bearing legs could have shipped without the
harness ever having been written, which is how a "prerequisite" quietly becomes optional. Leg
1 has no such hole — every leg in the table reaches it, directly or through 2 — so moving the
owner also closes the reachability gap rather than merely relabelling it. Until the harness
exists, "tested revert" means a human ran `sqitch revert` once, and that is worth saying out
loud rather than implying a suite covers it.

**Backfills must be re-runnable. The precedent this document cited twice for that rule does
not hold, and the rule stands anyway.** Legs 4, 6 and 7 all backfill, and the
half-deployed-state rule below says a partial run has to be safe to re-run from the start.

Two drafts tried to ground that in `sql/deploy/pricing-plans-amount-cents.sql` and both were
wrong about the file. The first said it "raises an exception on any row it does not
recognize"; there is no `RAISE` anywhere in it, and the `CASE` at `:30-33` has an `ELSE`, so no
row is unrecognized. (The pre-flight `RAISE EXCEPTION` shape that sentence describes is real,
but it lives in `sql/deploy/tenant-scoped-payments.sql:117,160`.) The second kept the
conclusion and changed the mechanism: `:35` and `:61` are `ALTER TABLE … DROP COLUMN amount`
with no `IF EXISTS` while the `ADD COLUMN` above each carries `IF NOT EXISTS`, so "on a
database where a previous attempt got partway through the tenant loop, the second run aborts."

**There is no such database.** The file opens `BEGIN;` at `:7` and closes `COMMIT;` at `:65`,
so the tenant loop is one transaction: a failure anywhere in it rolls the whole change back
and leaves nothing partly converted. And `sql/revert/pricing-plans-amount-cents.sql` re-adds
`amount` before dropping `amount_cents`, so the deploy→revert→deploy path finds exactly the
schema it expects. The missing `IF EXISTS` is a real asymmetry against its neighbour and worth
nothing operationally. Both drafts reasoned from a grep of the DDL without reading the
transaction boundary around it, and the second one had already been told the first was wrong.

The rule survives on its own terms rather than on that precedent, and the terms are stronger
than the example was: this milestone's backfills are **not** each one transaction. Leg 4
migrates every tenant schema's plans and publishes a v1 for each, Leg 6 calls Stripe from
inside the backfill — a network round trip that cannot be rolled back by a `ROLLBACK` — and Leg
7 writes a schedule row per relationship. A Stripe Price created before the transaction aborts
stays created. So each backfill in this milestone states its idempotency key — for Leg 4 the
presence of a v1 for that plan, for Leg 6 a non-null `stripe_price_id` **and Stripe idempotency
keys on the Product and Price creates**, for Leg 7 an existing schedule row for that (provider,
consumer) — and skips rather than raises on a row that already has it.

**Where a revert is lossy it says so in the script.** `sql/revert/pricing-plans-amount-cents.sql:9-14`
is the model: it states in a comment that the original decimal values cannot be recovered from
the integers, and reverts the schema anyway. `sql/revert/enhanced-pricing-model.sql:38-41` is
the counterexample and is cited here as one — it silently runs
`DELETE … WHERE ctid NOT IN (SELECT MIN(ctid) … GROUP BY session_id)`, destroying rows on the
way back with no comment and no ABOUTME. A revert that deletes data without saying so is worse
than one that refuses. Say which of the two shapes each revert is, in the script, at the top.

**And one test per dual-write window.** The windows are the riskiest thing in the
sequencing — Leg 5 through Leg 9a for `plan_scope`, Leg 7 through Leg 9a for
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

Plus one tenancy invariant (**Leg 4**, with the `clone_schema` change, then extended in Leg 7
for `pricing_schedules` and again in **Leg 10** for `metering_events` — the four tables it
names do not all exist until Leg 10, and an earlier draft stopped the extension at Leg 7),
because `clone_schema` is silent when it is wrong: onboard a
tenant, then assert that the tenant's schema contains none of `pricing_plan_versions`,
`pricing_components`, `pricing_schedules` or `metering_events`, and that a schedule written
for that tenant is readable from a DAO connected to its schema. Both halves are needed — the
first catches the exclusion list rotting as tables are added, the second catches a query that
forgot to qualify.

**A third half, because the first two are blind to everything that is not a table.** The test
also compares the tenant schema's `pg_proc` count against the `registry` baseline and fails on
any excess. Without it the invariant passes while 212 copied `btree_gist` C functions sit in
every tenant schema, because the assertion is a list of four table names and a stray function
is not a table. This is the assertion that would have caught the extension-placement trap
above, and it is cheap: one `SELECT count(*) … WHERE pronamespace = …::regnamespace` per
schema. **It runs as a superuser under `Test::PostgreSQL`, which is precisely why it is a
count and not an error check** — the copy that fails in production succeeds in CI, so the
only observable is the population.

It asserts nothing about `<tenant>.pricing_plans`, which legitimately
exists and holds rows until Leg 9b; the test flips to include it in that leg, and the reason
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
run is a red X nobody is required to look at. The design has spent seventeen legs arriving at
a single criterion that is first evaluated on a workflow structurally incapable of reporting
failure. **Removing `continue-on-error` and protecting `main` is part of Leg 3a**, not a
follow-up: it costs minutes, and every leg after it is worth less without it. The reason it
belongs in 3a specifically is that 3a is the first leg with a real-Stripe result worth
gating on.

**And that diagnosis is incomplete in the way that matters: the workflow is empty, not
masked.** `stripe-e2e.yml:27-29` reads `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY` and
`STRIPE_WEBHOOK_SECRET` from `secrets.*`, and the repository has none —
`gh api repos/Tamarou/Registry/actions/secrets` returns `{"total_count":0,"secrets":[]}`, and
so do the organization-secrets and variables endpoints. So the key is the empty string, every
file in `t/stripe-live/` takes the `skip_all` at
`Test::Registry::StripeConnect::available()` (`t/lib/Test/Registry/StripeConnect.pm:29-31`
requires an `sk_test_` prefix), and `prove` exits 0 on an all-skipped run. The most recent
Stripe E2E run ends `Files=4, Tests=0` / `Result: NOTESTS` with every step green. **Removing
`continue-on-error` changes nothing**, because there is no masked failure underneath — both
masked steps are genuine passes. The milestone's single pass/fail criterion, and Leg 9a's
explicit merge gate ("the full suite plus `stripe-e2e` are green"), are satisfiable today with
zero live-Stripe assertions ever executed, and would remain so after Leg 3a as previously
written.

This document states the governing rule itself, eight hundred lines earlier — **"a gate that
skips is not a gate"** — and applied it to `t/e2e/` while missing that the acceptance gate is
the thing currently skipping. So Leg 3a owns three items and not two, in this order:
**provision the three Actions secrets** (`sk_test_`, `pk_test_`, and the webhook signing
secret — perigrin's action, not an implementer's, and the only one on the critical path that
cannot be done by writing code); **add a fail-fast step asserting `STRIPE_SECRET_KEY` begins
with `sk_test_` before `prove` runs**, so a missing or rotated-away secret is a red run rather
than a `NOTESTS` pass; and only then remove `continue-on-error` and protect `main`. If the
spike's long-lived-account fallback is taken, its `acct_` id is a fourth secret.

One correction comes with it: `.github/workflows/ci.yml:128` comments that "Real keys live in
the stripe-e2e workflow." They do not, and that sentence is the likeliest source of this
document's own assumption. It is fixed in the same commit.

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
  `application_fee_amount`. Same test as `tiered`, but it passes only *after* Leg 1 acts: the
  seeded Registry Plus plan ($100/mo plus 1%) **is** a named consumer today, which is why Leg 1
  retires it from the menu. Deferring the hybrid and leaving Plus sellable are not compatible
  positions — see "So Plus is retired from the menu in Leg 1" above. Note this is narrower
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
   ships in Leg 8, dropped in Leg 9b. Dropping them when their successor *table* landed would
   have broken collection with no resolver to fall back on.

A third round found that two of those four corrections had over-shot, and turned up five
things the earlier rounds had not looked for:

9. **`<tenant>.pricing_plans` is live, and (5) very nearly deleted it.** The second round
   asserted the tenant-schema copies were empty clones and specified a migration to drop
   them. That was wrong. `enhanced-pricing-model.sql:79-142` migrated *rows* into every
   tenant schema, `PricingPlan.pm:66-72` deliberately uses the unqualified table name, and
   the charge path reads it through `Payment.pm:517` → `Session.pm:164-166`. Acting on the
   earlier text would have deleted every tenant's program pricing. The rows are migrated up
   to `registry` in Leg 4 — **with every reader repointed in the same commit**, per (34) —
   and the tenant tables dropped in Leg 9b, once nothing reads them.
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
    structural rather than a preference, but there is no revocation to order against. The
    deauthorized event itself survives — an earlier draft of this line said it did not — and
    becomes the backstop that tells us the Registry-initiated path was skipped.
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
    after (24) added Leg 3a, **32 to 51** after (29) and (30), **39 to 58** after (32)
    through (36), **57 to 81** after the round that added Legs 5a and 13 and re-costed
    3a, 3, 4 and 8 against what they had actually accumulated, **65 to 90** after (38)
    through (41), **66 to 91** after (42) through (45), and **71 to 97** after (46) through
    (49). That is seven revisions, and an earlier draft called them "all upward," which
    is wrong twice: the 52-72 → 33-49 step was the change of unit, not a re-costing, and
    32-51 lowered the floor while raising the ceiling. What is true is narrower and still the
    point — **every revision since the unit changed has raised the ceiling**, five in a row,
    and the only downward movement in the whole sequence was an artifact of switching from days
    to sessions. Sequencing says why the direction matters more than the number: a ceiling that
    has risen five consecutive times means the estimate is not converged, rather than merely
    pessimistic. A later draft read one small revision as convergence and the next revision
    falsified it; the retraction is above, in the estimate section itself.
    The re-costing also changed the *shape* of the estimate, not just its units: work that is
    wide and shallow (Leg 2's 21 test files, Leg 5's 1,412 lines of templates) is expensive in
    sessions in a way it was not in days, because reading is what spends a context window,
    while a small careful change is cheaper than its risk suggests. Leg 0 was the example of
    that second point at 1-2 sessions and is no longer one: (30) gave it locking, a capacity
    re-check and logging, later rounds gave it idempotency metadata in all three Stripe
    clients, a request timeout, two indexes written with the per-tenant loop and the
    revert-test harness, and its row now lists **fourteen** separate concerns at 7-9 sessions —
    round 9 added the `__tenant_slug` override and the `latest_run` cross-run read, and this
    sentence still said twelve at 6-8. The principle held; the example moved, and kept moving.
23. **Accounts v2, `losses`/`fees` to Stripe, full dashboard** — (14) is answered, and the
    recommendation it carried is corrected. "v1 accounts with controller properties" was
    wrong twice: controller properties are the migration path for platforms already on v1,
    and the claim that v2 "buys nothing this milestone needs" was backwards. A v2 `Account`
    carries Merchant and Customer configurations at once, which is this design's own
    "provider sells to consumer" relation expressed in Stripe's object model — and Registry
    is currently paying for the v1 version of it, maintaining a Stripe `Customer`
    (`Subscription.pm:59-64`) alongside the connected `Account`. **Leg 9a** collapses the pair —
    (27) below moved it there off Leg 3's critical path, and this sentence still said Leg 3.
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
      creates a connected account — but it removes `/v1/oauth/deauthorize`, which (13) had built
      the disconnect design on. It does **not** remove `account.application.deauthorized`; this
      line said it did, and "`account.application.deauthorized` survives" above corrects it.
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
    `main` has no branch protection. Seventeen legs converging on one acceptance criterion,
    evaluated by a workflow that cannot report failure. Fixed in Leg 3a, which is the first
    leg with a real-Stripe result worth gating on.
27. **The Customer-configuration collapse moves from Leg 3 to Leg 9a.** It is the only part of
    Leg 3 with no deadline, and Stripe supports adding a configuration later without
    re-collecting requirements. It also joins the column it obsoletes:
    `tenants.stripe_customer_id` was already dropping in what is now Leg 9b, one deploy after 9a adds the configuration. Named the mechanism while
    moving it — `customer_account`, not `customer` — because "collapses the pair" is not
    something an implementer can type.
28. **Four smaller corrections, recorded rather than quietly fixed.** `tenants.platform_
    pricing_plan_id` was described as **dropped** in the data model and dual-written
    everywhere else — a Leg 7 author reading only the data model would have broken collection
    for two legs. "Leg 0 ships alone and first" survived the renumbering that put Leg 1 ahead
    of it. The tenant lookup Leg 3 needs was said to be "already written" at
    `Webhooks.pm:148-162`; that method is a blind `UPDATE` returning `->rows` and yields no
    tenant identity, so Leg 3 writes a `SELECT`. And two counts were wrong: installments are
    ~3,000 lines, not ~3,700, and there were fourteen legs, not twelve. That second count has
    since moved again — sixteen, once the Leg 5 fork became its own decision task (5a) and the
    acceptance test became its own leg (13), and seventeen once Leg 9's additive half and its
    drops had to sit a deploy apart (9a, 9b). A leg count that keeps rising is scope discovery,
    and it is recorded here rather than silently corrected in the table.

Two more are perigrin's calls rather than a review's findings. The twenty-four after them (31-54)
are what the later adversarial review rounds forced, listed in the order the rounds ran
rather than by weight:

29. **Leg 5 is rewrite-or-delete, decided after Leg 4.** The spec had the workflow rewritten
    in the leg table and the CLI declared sufficient under "Out of scope", which is a
    contradiction the completeness pass caught. Resolving it by picking now would have meant
    picking from a line count; the diff that settles it does not exist until the version and
    component tables do. So the fork is recorded rather than closed, with its criterion under
    "Sequencing", the decision itself filed as its own task (Leg 5a, one session, a Leg 4 exit
    gate) so that Leg 5 is not filed against an unresolved fork, and a `1-4` range that says
    plainly that nobody has agreed to the work. The floor is 1 rather than 0 because even the
    delete branch closes the two entry points and the `ReviewActivatePlan.pm:101-115` call. The
    two branches are not symmetric: delete also rewrites acceptance invariant 5, which
    compares the workflow's output against the CLI's and has nothing to compare against once
    the workflow is gone.
30. **The bar moved from "PriceOps aligned" to "ready to take money."** Five findings sat
    outside PriceOps and inside the money path, and a correct pricing model over a charge path
    with no row locks and no logs would have been aligned and still not safe to switch on.
    Folded in rather than filed: row locking and a capacity re-check at capture, plus
    structured logging keyed on Stripe's `request_id`, into Leg 0; the quote's currency into
    Leg 9a; the CSP widening into Leg 12; and the rollback subsection under "Money movement",
    which is the one with no leg because it is a property of how every leg deploys. Two
    sessions on the ceiling at the time, 49 to 51 — a figure five re-estimates behind the 65
    to 90 above, and left here as the record of what this decision alone cost.

    **The capacity re-check needs a branch for "capacity is gone," and neither this decision
    nor the Leg 0 row supplies one.** At capture the money is already Stripe's: the check
    cannot simply refuse, because refusing leaves a captured PaymentIntent with no enrollment
    behind it — the exact orphan the leg exists to prevent, arriving through the fix. Leg 0
    writes the branch explicitly: if the session is full at capture, the enrollment is created
    with `status => 'waitlisted'` and the payment is refunded. That is one more path to test,
    and it is the path that runs on the day a popular session fills between checkout and
    webhook — which is precisely when it is least acceptable for the answer to be undefined.

    **An earlier draft of this decision put that refund *inside* the transaction, and it was
    the one place in this document where a rule the document states twice was broken by the
    document itself.** The words were "refunded in the same transaction that would have
    completed it, with the refund recorded against the payment row rather than left to a job."
    Leg 0's whole correctness argument is that ROLLBACK undoes the work and Stripe's retry
    heals it (`:1573-1575`); a Stripe refund is not undone by ROLLBACK, which this document
    says about backfills at `:3264` and says as a rule for this exact transaction at
    `:2136-2137` — "the transaction does the minimum Stripe work, and anything that can be done
    before `begin` is." So: transaction opens, row locked, session found full, waitlisted
    enrollment inserted, `Payment::refund` (`Payment.pm:448-482`) calls `create_refund` at
    `:457` and the money leaves the tenant's balance, and then COMMIT loses the connection or
    the process is SIGTERMed mid-deploy. Postgres rolls back the enrollment, the status write,
    the refund bookkeeping at `:475-477` **and the dedup claim**. Stripe redelivers. The
    rollback restored `status = 'completed'`, so `Payment::refund`'s guard at `:449` passes
    rather than short-circuits, and the handler refunds a second time.

    Whether that second refund is caught depends on how much was refunded, and the dangerous
    case is the common one. A full refund is rejected by Stripe as already-refunded, `:465`
    dies, and the event becomes a three-day poison retry with the money gone and the row
    showing a captured, un-refunded payment and no enrollment. A **partial** refund — one
    child's seat lost from a multi-child cart, which is one payment row (`:1896`) — is
    *accepted*, because nothing distinguishes the retry from a second legitimate partial. That
    is a genuine double refund out of the tenant's balance, and it is the case an after-school
    business hits first.

    There is no idempotency key available to stop it. `Service::Stripe::create_refund` →
    `create_refund_async` → `_request_async('POST', 'refunds', $params)` passes no fourth
    argument, so `$idempotency_key` defaults to `undef` at `:25` and the header is never set at
    `:32` — while `create_payment_intent_async` at `:72-76` does thread one through. The
    asymmetry is the bug. Leg 3's refund-key rule (`:1913-1914`) derives the key from
    `drop_request_id`, which does not exist for a capacity refund, and Leg 0 ships before Leg 3
    anyway, so for the whole interval between them this refund has no key at all.
    `metadata[registry_idempotency_token]` does not close it either — this document says at
    `:1637-1642` that it is a search handle, not a request-dedup header.

    **So Leg 0 commits first and refunds after.** Inside the transaction: the waitlisted
    enrollment and `status => 'refund_pending'`. After COMMIT: the Stripe refund, carrying
    `Idempotency-Key: refund:capacity:<payment_id>`, then the refund id recorded. A crash
    between the two leaves a `refund_pending` row, which is a state a human and a sweep can
    both see — unlike a rolled-back refund, which leaves no trace on our side at all. Leg 0
    also gives `create_refund` an idempotency-key parameter, since it does not have one, and
    Leg 3's rule at `:1913-1914` extends to cover every refund Registry issues rather than only
    drop-initiated ones.

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
    makes changing it something other than hand-typed SQL." Leg 11 is position 14; Decision 3
    requires Leg 3 to merge before the first tenant onboards, at position 5. Nothing enforces
    an ordering between them, so every tenant onboarded in between is charged nothing for
    nine legs — on a charge path that is otherwise working, which is the failure mode that
    looks exactly like success. Setting the rate is a one-line data migration and goes with
    the deadline it shares; Leg 11 keeps the tooling, which was always the part that was work.
34. **Four stranded-caller defects across three legs, and all four are now sequenced against
    it.** ("Four legs" in an earlier draft was a miscount: two of the four are both Leg 7.) They
    are the same mistake four times — a leg that moves a *writer* or an *artifact* one or more
    legs ahead of the leg that moves the *reader*. Leg 4 repoints `PricingPlan->create` at the
    registry table while `get_pricing_plans` still reads the tenant one, enrolling children
    free for four legs. Leg 6 backfill-publishes for tenants that have no Stripe account to
    publish to. Leg 7 drops `pricing_relationships` while `PricingPlanSelection` still reads it
    as step 4 of tenant signup. And Leg 7 deletes `DAO::PricingRelationship` — the *class*,
    not the table — which `PricingPlanSelection.pm:10` `use`s at compile time, so the step
    fails to load rather than failing to find a row. That fourth one is the generalization the
    other three did not force: **retention follows the name in the caller**, and a `use` line
    is as load-bearing as a table name. The rule the spec had for columns — supersede early,
    drop late — now covers tables, write cutovers and module deletions alike, and each site
    says so where it happens rather than in a general principle nobody re-reads.
35. **Two migrations as written would not deploy.** The `pricing_schedules` exclusion
    constraint needs `CREATE EXTENSION btree_gist` (the operator class for `uuid` `=` inside a
    GiST index is not in core) and cannot call `uuid_nil()` (also not core) — a literal
    all-zeros uuid replaces it. And every column, index or table change in Legs 0, 1, 3, 4
    and 9 must loop over
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
37. **The document is too long for what it is, and the length is kept deliberately — for
    now.** A review round measured roughly 450 to 500 removable lines with no decision lost:
    items 5-54 of this list are a changelog rather than a set of standing decisions, and the
    thirty-odd "an earlier draft said…" passages in the body each carry a conclusion that is
    load-bearing wrapped in a refutation that is not. The recommendation is correct as
    written. It is declined at this stage for one reason: **the refutations are the only
    record of what has already been tried and rejected**, and this spec has been revised
    across eight adversarial review rounds in which the same wrong answers were proposed
    more than once. Stripping them before the plan exists would invite a re-litigation the
    document has already paid for. The cut happens at the point where it costs nothing — when
    `superpowers:writing-plans` extracts per-leg issues from the table, the issues carry the
    conclusions and this document keeps the argument. Two of the refutations are exempt from
    any future cut because the wrong version is a trap an implementer would fall into
    independently: `<tenant>.pricing_plans` is live, and the superseded `clone_schema` file
    edits silently do nothing. The half of that finding that is **not** declined is the leg
    table: it carries seventeen issues in seventeen lines and names no files. Per-leg file
    manifests are a mechanical extraction from prose already here, and they are the first
    thing `writing-plans` produces.
38. **A sqitch verify script is a live reader, and thirteen of them are stranded.**
    `t/database/migration-verification.t:24-27,62-64` runs `sqitch verify` with no change
    argument, so every deployed change's verify script is re-run against the *final* schema. A
    verify written in 2025 that selects from `registry.payment_schedules` is therefore an
    assertion Legs 1, 2 and 9b have to keep true, delete, or rewrite — indistinguishable in
    consequence from a caller in `lib/`. This is (34)'s rule with a different file extension,
    and the spec had found exactly one of the thirteen. It is recorded as its own decision
    rather than folded into (34) because the *search* is the finding: "grep `lib/` for the
    name" was the habit, and `sql/verify/` was outside it. Legs 1, 2, 7 and 9 are re-costed —
    Leg 7's inclusion is (44), one round later.
39. **Three errors this document introduced in a previous fold-in, corrected rather than quietly
    replaced.** The first: a round asserted Stripe's v2 doc pages send `2026-07-29.preview` and
    pinned the target to `2026-03-25.dahlia` to avoid a preview channel. Fetching the pages
    disproved it — both `accounts/create` and `event_destinations/create` send
    `Stripe-Version: 2026-07-29.dahlia`, a GA version, and the target moves to it. The second:
    a round moved the `stripe_connect_ready` gate to `_render_data` on the reasoning that
    `Payment.pm:57` "is the page view" and does not pass through `process`. `process` spans
    `:22-59`; `:57` is inside it. The gate moves again, to `prepare_payment_data` (`:61`), the
    one function both render paths reach. **The third, found a round later: "a proration
    collects zero" was an over-read of the same sentence an earlier draft had under-read.**
    Stripe scopes the escape clause twice — *"invoices you create outside of a subscription
    billing period"*, exemplified by *"proration invoice items that are immediately
    invoiced"* — and says on the same page that the fee is taken from *"the final invoice
    amount, including any bundled invoice items."* A default `create_prorations` proration is
    bundled onto the next cycle invoice and **is** charged the percentage. The hole is real only
    for `always_invoice` and out-of-cycle invoices. `proration_behavior: 'none'` survives as the
    choice; the reason for it is narrowed. All three errors survived a review round each, which
    is the argument for the refutation passages (37) declines to cut — and the pattern in all
    three is the same: a quoted sentence read without its scope.
40. **A round-7 finding is retracted in full.** That round claimed
    `sql/deploy/pricing-plans-amount-cents.sql` was non-idempotent on re-run and generalized a
    rule from it. Both mechanisms named were wrong, and the file wraps `BEGIN;` (`:7`) to
    `COMMIT;` (`:65`) — one transaction, no partial state, and its revert re-adds `amount`. The
    rule it was grounding is still wanted, so it is re-grounded on a real instance from this
    milestone: **Leg 6's backfill calls Stripe mid-migration, and a re-run without idempotency
    keys double-creates Products and Prices.** A retracted finding is recorded rather than
    deleted because the rule outlived the evidence, and a reader who remembers the claim
    deserves to find the correction where the claim was.
41. **Five money holes the design had not named, now owned by legs.** A waitlist promotion
    enrolls a child in a paid program with no quote and no payment row, and it is automated
    (Leg 8). The storefront runs a second pricing engine — `min(amount_cents)` over unfiltered
    rows — that advertises a price the checkout does not charge (Leg 4). Refund approval is
    open to every instructor and the amount is checked only for shape, against a family cart
    that is one payment row (Leg 3). A defined-zero trial kills `DateTime->from_epoch` between
    Stripe's subscription create and Registry's tenant write, leaving a live subscription
    Registry cannot see (Leg 0). And the payment-row reuse guard is a deny-list of one, so
    re-enrolling after a refund drives the refunded row back to `completed` and erases the
    refund's record (Leg 0). None is caused by this milestone; all five are live today, and
    four of the five are on a path this milestone rewrites anyway, which is why they are legs
    rather than follow-ups. The refund idempotency key this document proposed is also
    corrected: derived from payment id plus amount, it collides on two children dropped at the
    same price from the same cart, and Stripe would replay the first refund's response for 24
    hours while the second silently does not happen.
42. **The Stripe destination account is picked by an attacker-writable POST parameter, and this
    is the worst defect any round has found.** Every prior round asked what the payment step
    *does* with `__tenant_slug`; none asked where the value comes from. It comes from the
    verified Host header on the first step only (`Workflows.pm:52-58`) and from the raw request
    body on every step after (`:351`), and the base step class passes its input straight through
    to a jsonb merge in which the later write wins. The enrollment workflow has a passthrough
    step two positions before payment. Whoever POSTs a foreign slug there redirects the
    settlement, the merchant of record, and the fee rate for the whole run. The fix is to apply
    the server override on every step rather than the first, in Leg 0. The webhook path that
    looks like the same bug is not one: signatures are mandatory, the metadata is Registry's own
    snapshot, and `event.account` really is absent on destination-charge platform events.
43. **A concurrent tenant signup changes what the current one is charged.**
    `TenantPayment::get_subscription_config` discards the run it is holding and calls
    `$workflow->latest_run($db)`, which is the DAO base `find` ordered `-desc created_at` — the
    newest run of that workflow on the platform. At `:339` the result is handed to
    `create_subscription_with_config`. This has been invisible because signups have been serial;
    it stops being invisible on the first day two prospects overlap. Leg 0. The general form is
    worth carrying into `writing-plans`: **`latest_run` is never the right call in code that
    already has a run**, and this document should not assume it is the only site.
44. **The verify sweep missed the leg that drops a table without dropping a column.** (38)
    built its list from Legs 1, 2 and 9 (now 9b) — the two column-droppers and the big table-dropper —
    and Leg 7 is neither, so `registry.pricing_relationship_events` and the four objects that
    ship with it (`pricing_relationship_current_state`, `get_next_aggregate_version`,
    `ensure_event_sequence`, `get_relationship_state_at`) went uncounted, along with the verify
    script that reads three of them. Two smaller corrections come with it:
    `pricing-relationship-events.sql:25` was miscounted under Leg 2 — the all-zeros literal
    there is a probe argument to a function, not the tenant — and
    `unified-pricing-infrastructure.sql:47-49` reads the tenant with a plain `SELECT`, so it
    goes vacuous rather than red. The corrected count is **fourteen distinct files and sixteen
    per-leg obligations**, not thirteen; the sentence saying it understated the obligation by
    twelve files understated it by one more. **The rule (38) stated was right and the way it was
    applied was not: "grep `sql/verify/` for the name" has to run in every leg that drops
    anything, not in the legs a reviewer happens to think of as migration legs.**
45. **A launch-rate change fails the production deploy, and this is a sequencing constraint
    rather than a test to update.** `bin/post-deploy-smoke-test.sh:61` greps the live landing
    page for the literal `2.5%`; `docker-entrypoint.sh:63-71` kills the server when the smoke
    test fails, which is how Render is told to roll back. Two Playwright specs assert the same
    string and CI runs one of them. So Leg 3's rate decision is not "pick a number and update
    the copy" — it is a number that has to move in the same commit as three assertions outside
    `templates/`, or the deploy that carries it rolls itself back.
46. **Run data is a trust boundary, and (42) closed one key rather than the class.** The fix
    that entry named — re-derive `__tenant_slug` on every step — is right and too narrow. The
    same passthrough writes `user_id` and `payment_id`, and both are load-bearing. `user_id`
    survives because `Workflows.pm:270` refuses to overwrite a value that is already set, and
    the comment there calls that guard safe *because* it is idempotent; idempotence is what makes
    a planted identity permanent, and `AccountCheck.pm:68-92` then advances the run on the
    planted user's mere existence without ever comparing it to the session. `payment_id` is
    worse, because the value does not have to be a scalar. `WorkflowStep::expand_form_params`
    re-nests `payment_id[!=]=<uuid>` into a hashref, `_arrayify_numeric_hashes` leaves it alone
    because `!=` is not numeric, and `WorkflowSteps/Payment.pm:162-167` hands it to
    `SQL::Abstract::Pg` as the entire `WHERE` clause. Rendered against the project's own
    installed version, that is `UPDATE payments SET amount_cents = ? WHERE id != ?` followed by
    `DELETE FROM payment_items WHERE payment_id != ?` — every *other* payment row in the tenant
    repriced, and every other row's line items gone. It takes one POST field and no leaked
    identifier. So Leg 0 owns a rule, not a patch: **the server-owned key set is re-derived on
    every step, and a run-data value bound for a `WHERE` clause must be a plain scalar.** The
    third instance is not a key at all — `MultiChildSessionSelection:57-64` accepts any
    `session_for_<id>` parameter into `%selections` while the capacity, age and completeness
    checks iterate the server-derived `@children`, so a child nobody selected is enrolled and
    never priced. That one is structural and belongs with the enrollment resolver in Leg 8, with
    a subset check in Leg 0 as the cheap immediate guard.
47. **`sqitch` is never reverted and Render always reverts, so Leg 9 had to become two.** The
    rollback path is asymmetric and the document had not said so: a failed smoke test kills the
    server (`docker-entrypoint.sh:63-71`) and Render restores the previous *image*, while
    `deploy_schema` only ever runs `sqitch deploy`. The previous release is therefore guaranteed
    to run against the newer schema, and a leg that stops the second write and drops the columns
    in one deploy leaves the rolled-back image writing to columns that no longer exist. Leg 9a
    is the additive half — quote columns, the reader repoints, the dual-write removal — and it
    has to be live through one full deploy cycle before Leg 9b drops anything. This is the same
    expand/contract rule the milestone already applies to Legs 3 and 8; it had simply never been
    applied to the leg whose whole content is a contraction.
48. **`applies_to` is a metering label, not a resolution filter.** Leg 10 adds the column and the
    event vocabulary, and the temptation is to have resolution step 4 emit only the components
    whose `applies_to` matches the event being priced. It must not, and the reason is the defect
    this design exists to close: every component published before Leg 10 has `applies_to` NULL,
    so a filtering step 4 emits zero line items for exactly the plans that predate the column,
    which is a free enrollment. **Step 4 stays unfiltered and Leg 10 does not touch it.**
    Filtering becomes arguable only once a backfill has given every live component a value, and
    that backfill is not in this milestone.
49. **A component's money comes from `pricing_plans.amount_cents` and from nowhere else.** Leg 4
    migrates each plan to a v1 with components, and the plan row carries the price twice: in
    `amount_cents`, and inside `pricing_configuration` under keys like `monthly_amount`. They
    disagree about units. `unified-pricing-infrastructure.sql:125` seeds `"monthly_amount":
    200.00` — dollars — while `Subscription.pm:109` writes `monthly_amount => 20000` with the
    comment "`$200.00` in cents" and `TenantPayment.pm:145` copies `amount_cents` into the same
    key. Session plans authored through `ReviewActivatePlan.pm:107` have no `pricing_configuration`
    money at all. A migration that reads the JSON is therefore reading a field that is sometimes
    dollars, sometimes cents and sometimes absent — a hundredfold error in whichever direction
    the seed row happens to win. Leg 4 reads `amount_cents` and asserts that every migrated plan
    had one.

50. **`registry` is a schema `clone_schema` copies out of, so nothing belongs in it that a
    tenant should not have its own copy of.** (5) excluded the new *tables* from the copy, and
    the body then stated the function half as a rule about *trigger functions* — put Leg 4's
    four in `public`, because `clone_schema` re-declares everything in `pg_proc` for the source
    schema. The rule is not about triggers; it is about anything that
    lands a function in `registry`, and Leg 7's `CREATE EXTENSION btree_gist` is the case that
    proves it, because nobody authoring an extension line thinks of themselves as adding
    functions. Bare `CREATE EXTENSION` installs into `search_path[0]`, and 45 of 64 scripts in
    `sql/deploy/` open with `SET search_path TO registry, public`; the extension's ~212
    `LANGUAGE C` functions then get copied into every tenant schema, which only a superuser may
    do. `Test::PostgreSQL` runs as `postgres` and CI goes green with 212 stray functions per
    tenant; Render's `registry_db_user` has `rolsuper = false`, so production gets
    `permission denied for language c`, `clone_schema` aborts, and `Tenant->create` rolls back.
    Onboarding stops in production only, on the milestone whose purpose is onboarding paying
    tenants. Every migration in this milestone names a schema on `CREATE EXTENSION`, and the
    tenancy invariant test grows a third assertion: the tenant schema's `pg_proc` count against
    the `registry` baseline. It is a count and not a permission check precisely because the test
    runs as a superuser and would never see the error.

51. **A leg that deletes a module greps `t/` for its name, not just `lib/`.** The `t/` sweep ran
    for Leg 1 and for no leg after it, which left Leg 7 two files deep and Leg 9a five. The cost
    is trivial — three deletions and five fixture rewrites, all inside legs already costed to
    touch those subsystems — and that is the point: the expense is not the fix, it is a leg that
    ends with `prove -lr t/` red at its own boundary under a stated 100%-pass gate, found by
    whoever runs the suite rather than by whoever planned the leg. The worst of the eight is
    `t/controller/tenant-create-session.t:35`, which calls a class it never `use`s and so fails
    at runtime rather than at load.

52. **The acceptance gate is empty, not masked, and (26) diagnosed only the mask.** (26) found
    `continue-on-error: true` on both real-Stripe steps and treated removing it as the fix.
    Removing it changes nothing: the repository has no Actions secrets at all
    (`gh api repos/Tamarou/Registry/actions/secrets` → `total_count: 0`), so
    `Test::Registry::StripeConnect::available()` finds no `sk_test_` prefix, every file in
    `t/stripe-live/` takes its `skip_all`, and `prove` exits 0 — the most recent run is
    `Files=4, Tests=0`, `Result: NOTESTS`, all green. The masked steps are genuine passes. So
    Leg 3a's items are ordered: secrets first (perigrin's, and the only critical-path item that
    cannot be done by writing code), then a fail-fast assertion on the `sk_test_` prefix, then
    the `continue-on-error` removal and branch protection. This is the document's own
    **"a gate that skips is not a gate"** rule, which it applied to `t/e2e/` while missing that
    the acceptance gate was the thing skipping.

53. **Leg 0 commits, then refunds — the one place this document broke its own rule.** (30)
    added a capacity re-check at capture and a branch for "capacity is gone," and put the
    Stripe refund *inside* the webhook transaction. Leg 0's correctness argument is that
    ROLLBACK undoes the work and Stripe's retry heals it; a refund is not undone by ROLLBACK,
    which this document states about backfills at `:3264` and states as a rule for this exact
    transaction at `:2136-2137`. On a crash between the refund and COMMIT the rollback restores
    `status = 'completed'`, `Payment::refund`'s guard at `Payment.pm:449` passes, and the
    redelivered event refunds again — rejected as a duplicate if it was a full refund (a
    three-day poison retry with the money gone and no enrollment), *accepted* if it was partial
    (a real double refund out of the tenant's balance, which is the multi-child cart, the
    common case). No key stops it: `create_refund_async` passes no fourth argument to
    `_request_async`, so the header is never set, while `create_payment_intent_async` threads
    one through — the asymmetry is the bug. So the transaction commits `waitlisted` plus
    `refund_pending`, the refund goes after COMMIT under
    `Idempotency-Key: refund:capacity:<payment_id>`, and Leg 0 gives `create_refund` a key
    parameter. A crash then leaves a visible `refund_pending` row instead of no trace at all.

54. **A registered job is not a scheduled job, and neither scheduling mechanism works.** Both
    money-recovery jobs this milestone adds are pollers — `ProcessRefunds` (Leg 3) and
    `ReconcilePayments` (Leg 12) — and both were told to be "registered like the existing jobs
    (`Registry.pm:72-75`)", which is `add_task` and nothing more. The Render cron
    (`render.yaml:96-110`) was never given the `MOJO_SECRET` `fromService` block the worker has
    at `:87-91`, so `Registry.pm:36` kills it: every run across the full log-retention window is
    `Starting scheduler tasks...` → `MOJO_SECRET environment variable is required in
    production` → `Exited with status 255`. Beneath that, `./registry job <task>` is not a
    resolvable command (Minion's is `./registry minion job -e <task>`) and `set -e` would abort
    on the first one anyway. The in-process path, `setup_recurring_jobs` (`Registry.pm:830-898`,
    called once from `before_server_start` at `:479`), enqueues one delayed job per task and
    never re-arms — production ran each sweep exactly once at the 2026-08-02 boot and has been
    silent since. Leg 3 owns the repair because it ships the first job whose failure is a money
    failure. This is (50)'s shape one layer up: green everywhere a test can see, dead in
    production, and the only signal is the customer asking again.

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
- ~~**`sql/verify/stripe-subscription-integration.sql:9` asserts `tenants.stripe_customer_id`
  exists**, and Leg 9b drops it.~~ **Promoted out of this list and into Legs 1, 2 and 9b.** It
  was one of thirteen stranded verify scripts, not a lone check, and the sentence that
  accompanied it here — "a deploy-time failure in the one place with no test coverage" — was
  wrong twice: `t/database/migration-verification.t` covers it, which is exactly why it is not
  merely a deploy-time failure but a red test in a file whose name gives no hint that pricing
  work broke it. See "Each change also ships a verify script" under Testing, and (38).
- **Mixed-interval subscriptions may have superseded one of the four Stripe restrictions
  above.** The constraint that every item on a subscription shares `interval` and
  `interval_count` is stated here as absolute; Stripe has since added mixed-interval
  subscriptions under flexible billing mode. The design is *more* restrictive than Stripe
  requires, which is safe, so this is a possible simplification rather than a defect —
  confirm before **Leg 4** designs the per-(version, cadence) CHECK around it. Leg 4 is where
  the CHECK constraints land, not Leg 8; an earlier draft named Leg 8 and would have had the
  confirmation arrive five legs after the constraint it constrains.
- **A failed migration does not fail the deploy.** `docker-entrypoint.sh:20-24` warns and
  boots the app anyway, and `render.yaml:75`'s worker runs no migration at all. Not caused
  by this design, but a dozen or more migrations across seventeen legs make it much likelier to bite, and
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
