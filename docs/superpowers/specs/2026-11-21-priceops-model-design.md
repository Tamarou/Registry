# PriceOps model — design

Status: draft for perigrin's review. Base: `main` at 4e6664b. This design
supersedes the model sections of
`docs/superpowers/specs/2026-08-07-priceops-alignment-design.md` (the "August
spec") where the two conflict. It keeps the August spec's money and schema rules
(see "Rules that hold"). The in-studio bookings draft
(`docs/in-studio-bookings-design` branch) predates this model and is to be
rewritten on top of it; where the two disagree, this one wins.

## Why

Registry has re-made the same architectural decisions several times because
it never wrote down what PriceOps is for. The platform-is-a-tenant rule was
recorded in August and missed again in November. Drop and transfer were built
as admin flows instead of as the terms of what was sold. "Entitlement" means
three different things across the docs and code. Every new product (after-school,
in-studio, the platform's own plans) has had to decide afresh where its prices,
fees and rules live.

This document fixes the model once, in perigrin's terms, so the next product is
an instance of it, not another argument about it.

## What PriceOps is

**PriceOps is the software that models the relationship between a tenant and
its customers.** Each tenant is a tiny empire with its own customers. Anything a
tenant manages and sells through an offer and a payment is controlled through
PriceOps. Nothing a tenant sells through Registry exists outside it. Sales at
the studio's counter, through its own point of sale, are outside Registry.

**The platform is just a tenant.** Its customers are the tenants. What the
platform sells SACP and what SACP sells someone booking a wheel class are the
same relationship and use the same machinery: the same tables, steps and
screens. There are no platform-only paths.

**Everything in PriceOps is per tenant.** Tenant A has its own resources, offers
and entitlements, different from Tenant B's.

**PriceOps builds on Tier's "5 Pillars of PriceOps"**
(priceops.org, © 2022 Tier, Inc., CC BY-SA 4.0). It is a published methodology,
not something Registry invented. The pillars are:

1. a model of immutable, versioned plans;
2. a customer schedule;
3. metering of everything that might be monetized;
4. entitlement checks that name features, never plans;
5. tooling as the only way to change any of it.

This model fills in what the pillars leave open for a platform whose customers
are themselves sellers:

- the tenant chain;
- finite resources;
- the lifecycle policies that govern what a customer holds.

## The model

### Resource

Something a tenant controls access to. Examples:

- the seats in a class occurrence;
- clay;
- email sending;
- the right to run or create workflows;
- AI tokens.

A resource may be **finite** (an occurrence has 10 seats) or **unbounded** (a
send capacity limited only by policy).

### Offer

A tenant's terms for granting access to a resource. An offer has:

- **a price**, and **what it buys**: a discrete amount of a resource (one seat,
  a couple using two seats) or metered use of it (per pound, per 1000 emails);
- **policies**:
  - **payment**: one or more payment plans the customer chooses between:
    - one-time, possibly with a prepay discount;
    - instalments;
    - a recurring contract;
    - pay-as-you-go, for metered use;
  - **refund**: whether money comes back, how much, until when;
  - **change**: whether the entitlement can be moved, within what window, for
    what fee, to which targets;
  - **use**: what counts as using it;
  - **expiry**: when it lapses unused, and what that means.
- **conditions**: requirements the customer must meet to accept the offer,
  checked at acceptance against facts the tenant already holds. A sibling
  discount is an offer whose condition is "another child in this family holds
  an entitlement in this program". Conditions are declared data on the offer
  version, never code branches, and the customer sees each offer and its
  conditions rather than having the system pick one for them.

Offers are versioned and **immutable once published** (Pillar 1). A change to
an offer is a new version. A special arrangement for one customer is its own
offer version, never an override field. The model expresses every price in
effect.

### Entitlement

What a customer holds after accepting an offer and paying under one of its
payment plans. It records:

- the customer;
- the exact offer version, and so the exact policies it was sold under;
- when it is in effect (Pillar 2's schedule "phase");
- for a discrete entitlement, the specific units it holds (the seats in this
  occurrence);
- for a metered entitlement, the consumption recorded against it.

An entitlement's life (**used, changed, refunded, expired**) moves only through
its offer version's policies. No step carries its own refund, transfer or expiry
rule.

Customers see whatever word suits the offer: booking, reservation, ticket,
membership, plan.

**"Can X do Y?" and "X holds an entitlement to Y" are the same fact from two
sides.** The entitlement is the fact. The check (Pillar 4) asks it. Code always
asks about the resource or feature ("does this customer hold a seat in this
occurrence?", "may SACP send 500 more emails this hour?"), **never about a plan
name**. Where overrunning matters (seats, send caps), the check reads live state
at the moment of the request, not a cache.

### Payment

How an entitlement comes into being and is settled, as the accepted payment
plan dictates:

- up front;
- on an instalment schedule;
- every period of a contract;
- in arrears for metered use.

A tenant's take is shaped by the platform tenant's offer to that tenant. The
revenue share is a term of the offer SACP accepted from the platform, not a
special calculation. Today the charge-time rate is read from
`registry.tenants.platform_pricing_plan_id` (`RevenueShare.pm:15-50`), while
`registry.pricing_relationships` only backs the signup menu; under this model
the tenant's entitlement from the platform is the one source, and both of
those give way to it.

### Metering

Everything that might be monetized is recorded, **including what is free
today** (Pillar 3). Email sends, workflow runs and AI tokens are all recorded
from the day they exist, whether or not any offer prices them yet. A meter must
be readable synchronously, so a request can be refused at a cap.

## How PriceOps is driven: workflows, not code

**Product design workflows are the only way resources, offers and policies are
created or changed** (Pillar 5). Program setup is one. The platform tenant's
plan design is another, the same kind of workflow run by a different tenant.
Each of these is a workflow step:

- creating a resource;
- publishing an offer version;
- choosing its policies;
- granting an entitlement;
- moving an entitlement through its life.

There is no CLI-only path and no platform admin screen that tenants lack. Adding
a new offer, price or policy setting needs no code change and no deploy. Who
may run which workflow is data too; today's hard-coded `workflow_roles` map in
`Registry.pm` is one of the things that becomes data.

Workflow steps name Perl classes, and `CreateWorkflow.pm:55` takes the class
from the submitted form, which `WorkflowStep.pm:84-87` then loads. Before the
right to create workflows is anything a tenant can hold, step classes come
from an allowlist; a tenant composes allowed steps, it never names code.

That is what makes PriceOps developer-friendly here. Anyone allowed to author
workflows can build or change a product's pricing: Tamarou as the platform
tenant, or any tenant entitled to create workflows. New *kinds* of behaviour
(a new payment form, a new kind of policy) are new workflow steps. They are
never `if` branches on plan names or `plan_type` columns, and new shapes arrive
as declared data.

## The platform tenant's offers

The platform's resources include:

- **workflows**: the right to run particular workflows, and the right to create
  them;
- email sending;
- custom domains;
- payment processing, which is where the revenue share applies;
- in future, AI tokens.

Whether any of these is included in an offer or metered per use is the platform
tenant's product design choice, like any tenant's. The model supports both.
The business rule carried from the pricing strategy still guides that choice:
**never gate features that help customers make money.**

Granting a tenant a workflow is an entitlement, not a copy. Today a tenant gets
the registry's workflows copied into its schema at creation, so a workflow added
later, such as in-studio booking, never reaches an existing tenant without a
migration. Under this model the tenant holds an entitlement to run that
workflow, and gaining a new one is accepting an offer. Workflow definitions
live per tenant schema and no foreign key crosses schemas, so a held workflow
may still be copied into the tenant's schema; what changes is that the
entitlement, not the copy's existence, decides whether the tenant may run it,
and accepting the offer is what brings the copy.

## After-school, re-expressed

After-school already does all of this, on structures that don't say so:

| model | after-school today | what changes |
|---|---|---|
| product design | `program-creation`, `program-setup`, `session-creation`, `event-creation`, `pricing-plan-creation` | the one path that publishes offers and their policies |
| resource | a session's seats | made explicit; finite |
| offer | `pricing_plans` (a price plus early-bird/sibling `requirements`) | gains the policy set; the customer chooses among offers rather than the system picking the lowest total |
| payment policy | one-time; instalment schedules (#425, `pricing_configuration.schedule`); Stripe subscriptions in `Subscription.pm` | one policy offering one or more of these plans |
| entitlement | an enrollment tied to one child, plus the payment stamp | an entitlement referencing the offer version; the child is the after-school product's detail, not PriceOps' |
| refund policy | the drop flow and `ProcessDropRefund` | a policy on the offer, applied by a lifecycle step |
| change policy | the transfer flow: admin-approved, no lock, no money | a policy on the offer (window, fee, targets), applied with locks and payment |
| use policy | attendance | stated as the offer's use policy |
| expiry | nothing | stated: an occurrence-bound entitlement expires when its occurrence ends |

Today's drop and transfer defects have two causes. Drop approval never
advances because nothing runs a workflow's later steps without a person at the
screen: `Registry::WorkflowProcessor->new_run` processes only the first step
(`Utility/WorkflowProcessor.pm:9-14`), and the job that would carry a run
forward (`Job/WorkflowExecutor.pm`) is never registered. Transfer skips
capacity and moves no money because it was built as a standalone admin flow.
Re-expressing drop and transfer as policies fixes the second; the first needs
a driver for unattended steps, which every lifecycle step (refund, change,
expire) also needs.

## Rules that hold

Most of these come from the August spec. They are rules for the build, not a
description of today's code; where the code does not yet follow one, the rule
says so.

- **Immutability and stamping.** Offer versions are append-only and immutable,
  enforced in the database. Every charge stamps the offer version and terms it
  was sold under. Lifecycle steps read the stamped terms: refunds "resolve
  backwards, not forwards".
- **Absence is not zero.** If no offer resolves, refuse; never charge $0 by
  default. Every tenant always resolves to some offer from the platform tenant.
  Today's fallback to the Free plan at 0% when a tenant has no linked plan
  (`RevenueShare.pm:17-23`) breaks this rule and goes.
- **PriceOps never moves money.** It decides what is owed; Stripe moves the
  money and is the truth for it.
- **Stripe rules:**
  - direct charges on the seller's own Stripe account (see "Decided with
    perigrin");
  - `application_fee_amount` is omitted, never 0. The destination-charge code
    sends it unconditionally (`Payment.pm:357-359`, and a test asserts 0), so
    the move to direct charges fixes this too;
  - fractions versus percentages to at most 4 decimal places;
  - `proration_behavior: 'none'` whenever a recurring contract is modified (no
    code modifies one yet);
  - tenants connect Standard accounts through the v1 Accounts API
    (`StripeConnect.pm:17`). If that moves to Accounts v2, the settings chosen
    there are one-way doors.
- **Schema and tenancy:**
  - tables about the platform tenant's customers (tenants, and what they hold
    from the platform) live in the `registry` schema, as any tenant's customer
    tables live in its own; code reaches them fully qualified, and no foreign
    keys cross schemas. `clone_schema` copies the structure of every table in
    `registry` (`fix-clone-schema-identifier-quoting.sql:359-367`), so every
    tenant schema has these tables, empty unless that tenant has customers of
    its own;
  - payments live per tenant schema, so migrations loop over tenants;
  - one schedule phase is in effect at a time, enforced by an exclusion
    constraint (none exists yet; step 3 adds it).
- **Refunds are per entitlement**, never the whole cart. A `pending` refund is
  not terminal.
- **Revenue share comes only through Stripe.** Offline sales earn nothing for
  now (#410).
- **The launch rate:** Solo at $0 plus 2.5% is the platform tenant's offer to
  new tenants, published through product design like any offer. Today it is
  found by `metadata->>'launch_rate'` (`RevenueShare.pm:125-140`), a lookup by
  marker that the anti-goals rule out; it goes once the offer is published
  through step 4.

## What this drops from the August spec

- **"Entitlement" as the price resolver** (`PriceOps::Entitlement->quote`). The
  resolver is a quote; an entitlement is the held fact.
- **The system choosing the lowest-total plan.** The customer accepts a specific
  offer. Early-bird and sibling rules become distinct offers or offer conditions
  the customer can see.
- **The payment form fused into a component's `cadence`.** Payment is a policy
  offering one or more plans.
- **Migrations and metadata markers as the author of platform plans** (the
  August spec planned a CLI; none was built), and the `audience` split between
  revenue-share plans and the signup menu. The platform tenant authors its
  offers through the same product design workflow as anyone.
- **"The transfer chain moves no money."** Change is a priced policy.
- **Deferring metering and dropping tiered pricing** as out of scope. Metered
  entitlements are part of the model; tiered pricing is an offer shape,
  available when a product needs it.

## The platform tenant made real

The platform is still two rows (`registry` and `registry-platform`, #294). The
second has no schema, so code that walks tenants breaks on it and sweeps log
errors for it. Making the platform an ordinary tenant (one tenant, with a
schema, holding its offers to other tenants) comes first, because every other
step needs somewhere for the platform's offers to live.

**Code that asks "is this the platform?" goes,** and each answer comes from data
instead:

- checks against the all-zeros id: `PricingRelationship.pm:154`,
  `PricingPlanBasics.pm:68`, `PricingPlanSelection.pm:14`, `PricingPlan.pm:255`,
  `Registry.pm:1202`. #294 keeps that id so the rename is one migration; these
  checks are then removed as step 3 gives them data to read;
- `Tenant->platform`, which finds the platform by the slug `registry-platform`
  (`Tenant.pm:167`). The rename breaks it, so it changes in the same commit as
  the rename, or `is_platform_admin` is false for everyone and every
  `/platform/*` route returns 403 (`t/security/platform-nav.t`,
  `t/security/platform-admin-only.t`);
- `is_platform_admin` and the `/platform/*` screens become the `registry`
  tenant's ordinary admin role and screens (see "Decided with perigrin");
- `SendNotifications.pm:162` and `Payment.pm:341,374`, which branch on the
  platform slug, become reads of the tenant's entitlements and Stripe account.

**Which `slug <> 'registry'` checks stay.** A check stays only where `registry`
has already been handled another way: a migration loop that changed
`registry` first, or a connection where `connect_schema('registry')` is the
default connection. Every other check is a business rule that treats the
platform tenant as something other than a tenant, and goes. Before each one
goes, the job is tested against the platform tenant, because some would harm
it: the inert-tenant sweep (`Tenant.pm:364-368`) must count the platform as
active or it reports the platform for reclaiming. The known business-rule
checks are `TenantProcessor.pm`, `ProcessWaitlist.pm:73`,
`WaitlistExpiration.pm:72`, `Tenant.pm:364-368,571,674`, `ProgramListing.pm:269`
and the `registry-storefront` workflow (`Registry.pm:1282`,
`Tenant.pm:876-878`). The builder confirms the list with a search rather than
trusting this one.

## Order of work

Each step leaves `main` releasable with the suite green.

0. **Green CI on `main`.** The suite fails today; nothing else starts until it
   passes.
1. **The platform as a real tenant** (#294/#265): the rename, `Tenant->platform`
   in the same commit, the `registry` tenant's admin role replacing
   `is_platform_admin`, and the `slug <> 'registry'` checks handled by the rule
   above.
2. **Direct charges, with Stripe as the source of truth.** Charges, refunds
   and the payment form move to the selling tenant's account:
   - the Stripe client sends the `Stripe-Account` header (`Service/Stripe.pm`
     has no support for it);
   - refunds stop using `reverse_transfer` (`Payment.pm:362-383`);
   - the browser's Payment Element is given the tenant's account;
   - `application_fee_amount` is omitted at 0;
   - a Connect webhook endpoint, with its own secret, reads `event.account` to
     find the tenant instead of metadata (`Webhooks.pm`), and handles
     `charge.refunded`, `charge.dispute.*` and customer events;
   - the tests that pin destination charges are rewritten;
   - the builder checks in test mode whether a charge on the Connect platform
     account itself accepts a `Stripe-Account` header naming that account.
3. **Resources, offers with policies and conditions, and entitlements as
   first-class data.** Offer versions keep the immutability triggers that
   `pricing-plan-versions.sql` already has. The identity checks above read
   entitlements from here.
4. **The product design workflow steps** that publish offers and policies. Both
   day-one users run them: the platform tenant publishing its recurring
   revenue-share offer and the launch rate, and SACP publishing its in-studio
   offers. That retires the migrations and metadata markers that author
   platform plans today.
5. **Lifecycle steps** (accept and pay, use, change, refund, expire) that read
   the stamped policies, plus a driver that runs workflow steps no person is
   waiting on (registering `Job/WorkflowExecutor.pm` or its replacement) and a
   scheduled job that expires entitlements. Stripe-reported refunds and
   disputes from step 2 arrive here as lifecycle moves.
6. **After-school re-expressed:** enrollments as entitlements, drop and transfer
   as the refund and change policies, sibling discounts as offer conditions,
   before after-school sells anything.
7. **Workflows as entitlements:** a tenant's right to run a workflow comes from
   an entitlement, so new workflows reach existing tenants by offer.
8. **Metering** for email sends, workflow runs and, later, AI tokens, recorded
   whether priced or not. The email send cap becomes an entitlement check on
   that meter.

Day one is steps 0–5: SACP's in-studio offers and the platform's recurring
revenue-share offer are both live. Step 6 follows before after-school sells.
Steps 7–8 can follow after that.

## Goals

- One model, written down, that every product (after-school, in-studio, the
  platform's own plans) is an instance of.
- Adding an offer, price or policy needs no code change.
- Every entitlement's life is governed by the policies it was sold under.
- No platform-only code paths, screens or CLIs.

## Non-goals

- Building metered billing to Stripe in this project. Metering is recorded and
  readable; turning it into invoices waits until an offer needs it.
- A tenant-facing workflow authoring UI beyond what exists. The entitlement to
  create workflows is modelled; better tooling is separate work.
- Running old and new after-school paths side by side. With nothing sold,
  step 6 replaces the old path rather than coexisting with it.

## Anti-goals

- Plan names or `plan_type` in application branches.
- A pricing rule anywhere except an offer version.
- A platform-only path of any kind.
- Charging money by default when nothing resolves.

## Decided with perigrin

- **The platform tenant is `registry`, and the `registry` schema is its tenant
  schema.** The two tenant rows collapse the way #294 says: the `registry` row
  is deleted and the all-zeros `registry-platform` row is renamed to
  `registry`, so the sentinel UUID hardcoded across the code keeps resolving.
  Because `registry` is a tenant schema, anything that runs per tenant runs on
  it too, and nightly jobs cover the platform tenant. Migrations keep their
  `slug != 'registry'` loops, because each one changes `registry` first
  (`SET search_path TO registry`) and the loop reaches every other tenant
  once; that is not an exclusion.
  The platform's sales to tenants are ordinary entitlements in its own schema.
  That entitlement table replaces both `registry.pricing_relationships` and
  `tenants.platform_pricing_plan_id` as the record of what a tenant holds.
  `TenantProcessor.pm` and the other business-rule exclusions are covered in
  "The platform tenant made real".
- **Direct charges: each tenant owns its customers.** Every sale is charged on
  the selling tenant's own Stripe account (tenants connect Standard accounts,
  `StripeConnect.pm:17`), so the customer, payment method, refunds and disputes
  live there, and the platform takes its share as `application_fee_amount`.
  The code makes destination charges today (`Payment.pm:357-359`, and
  `transfer_data` on instalment schedules at `Payment.pm:142`). Moving to
  direct charges is step 2, done before the first real sale because no
  customers or payment methods exist yet to move.
- **Tamarou operates the platform tenant, and Tamarou's Stripe account is its
  account.** That account is also the Connect platform account, so the revenue
  share (the application fee on every tenant's sale) and the platform
  tenant's own sales to tenants both land there. The payment steps are shared:
  each tenant record names its Stripe account, and the `registry` row names
  Tamarou's. Every tenant holds a revenue-share offer from the platform; the
  platform tenant's offer from itself is an explicit 0%, so its own sales send
  no `application_fee_amount` by the ordinary "omitted, never 0" rule rather
  than by a check for the platform. Whether a charge on the Connect platform
  account itself takes a `Stripe-Account` header naming that account is
  unverified; the builder checks it with Stripe in test mode in step 2.
- **Alex administers the platform tenant.** The persona Alex
  (`docs/personas/alex.md`, which replaced Alice in 08c3a5a) stands in for
  perigrin and Tamarou: an ordinary admin of the `registry` tenant, using the same admin screens and workflows as
  any tenant's admin. The `/platform/*` screens, the `registry platform` CLI
  and `is_platform_admin` become that tenant's admin surface, not a separate
  one.
- **The platform's customers are tenants.** SACP and every other tenant are
  the platform tenant's customers, as organisations. An entitlement names its
  holder, which is a person for a studio's sale and a tenant for the
  platform's.
- **Tamarou keeps its share on a refund** unless Tamarou caused the sale to be
  wrong. That is a term of the offer between the platform and the tenant, not
  of the offer the customer accepted: the platform's revenue-share offer
  carries a refund policy of "keep the fee", with an exception the platform
  tenant's admin applies when the fault is Tamarou's.
- **Everything moves to the new model, and CI goes green first.** No product,
  in-studio or after-school, launches on today's pricing tables. Fixing the
  failing CI on `main` is the first step, so every later step can keep it
  green.
- **Stripe is the source of truth for money and customers; Registry follows
  it.** A refund issued in a tenant's Stripe dashboard, a lost dispute, or a
  customer changed there is applied to the matching entitlement as if a
  lifecycle step had done it: a full refund ends the entitlement and frees its
  resources, a partial refund is recorded against it, and a lost dispute ends
  it. Registry never contradicts Stripe and never re-charges to undo it.
  Dispute fees fall where Stripe puts them, on the tenant as merchant. This
  needs Connect webhook handling for `charge.refunded`, `charge.dispute.*` and
  customer events, which today's handler (`Webhooks.pm`) does not have.
- **The platform and SACP are both ready on day one.** The platform's
  recurring percentage-of-sales offer is part of the first slice, not
  deferred to later steps.
- **Nothing has been sold through Registry yet.** SACP still sells after-school
  and camps on Sawyer and in-studio on PlaceFull. There are no live
  entitlements to backfill, so offers are re-created under SACP's stated terms
  rather than the code's current behaviour: all sales final (refund: none),
  reschedule up to 48 hours before (change), and, for after-school, a make-up
  within one month of a missed class (use). Today's refund-on-drop is not
  SACP's policy.
- **Sibling discounts are live SACP policy** ("at all schools"), so an offer
  condition must be able to express them. Early-bird is not used.

## Settled details

These came up in the builder reviews; each is *(my call)*.

- **Identity checks move with entitlements.** Step 1 collapses the platform
  into one tenant and fixes what the rename breaks. The all-zeros id checks and
  the slug branches in `SendNotifications.pm` and `Payment.pm` turn into reads
  of entitlements in step 3, when entitlements exist.
- **Bootstrap.** Every tenant starts with seeded entitlements through the same
  tenant-creation step, including the revenue-share offer it is on. The one
  thing that exists before any workflow can run is the platform tenant's own
  row, its first admin and its right to run product design, created by the
  deploy migration as the row is today. That is the root, not a path: nothing
  after it is created any other way.
- **The minimum shapes for day one** (what steps 3–5 must support):
  - a finite, discrete resource (seats in an occurrence) with offers that use
    N seats each, and a per-booking cap on how many of an offer one booking
    may take;
  - a one-time payment plan;
  - a refund policy of "none" or "full, until a cutoff";
  - a change policy of window (hours before the occurrence held), fee, and
    targets limited to occurrences of the same offer. The fee is a one-time
    payment like any other, so the revenue share applies to it, and it is
    refunded automatically if the move cannot complete;
  - the platform's revenue-share offer: a recurring term whose price is a
    percentage of each sale the tenant makes, collected per sale as
    `application_fee_amount`, not invoiced;
  - expiry at the end of the occurrence;
  - use as optional attendance;
  - lifecycle moves reported by Stripe: full refund, partial refund, lost
    dispute.

  Extras sold with a booking stay out (they go through the studio's point of
  sale). Instalments, metered entitlements and offer conditions arrive with
  after-school and metering, in steps 6 and 8.
- **"Offer" is already used by the waitlist** (`Waitlist.pm`,
  `accepted_offer_ids`). In this model a waitlist offer is a time-limited hold:
  a discrete entitlement with an expiry policy. The waitlist's term is renamed
  to "hold" when step 6 reaches it.
- **Tenant-edited workflows.** Every tenant gets the `workflow-creation`
  workflow copied in (`Tenant.pm:873-882`), so a tenant may already have
  edited or added workflows. Step 7 queries every tenant schema for workflows
  that differ from the platform's and keeps them.
- **The Alex persona** (`docs/personas/alex.md`) says paid enrollment is live
  on destination charges. It is updated to this model in step 2.

## What's left to the builder

- Table and column design for resources, offers, policies, conditions and
  entitlements, within the rules above.
- Whether existing `pricing_plans` rows, which are configuration only, are
  converted to offer versions or re-entered through product design.
- How the lifecycle steps are grouped into workflows.
