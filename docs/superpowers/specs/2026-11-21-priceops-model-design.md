# PriceOps model — design

Status: draft for perigrin's review. Base: `main` at 4e6664b. This design
supersedes the model sections of
`docs/superpowers/specs/2026-08-07-priceops-alignment-design.md` (the "August
spec") where the two conflict. It keeps the August spec's money and schema rules
(see "Carried forward"). The in-studio bookings design is rewritten on top of
this one.

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
PriceOps. Nothing a tenant sells exists outside it.

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
special calculation.

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
a new offer, price or policy setting needs no code change and no deploy.

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
workflow, and gaining a new one is accepting an offer.

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

Today's drop and transfer defects (drop approval never advances; transfer skips
capacity and moves no money) come from building policies as standalone admin
flows. Re-expressing them as policies is the fix, not a patch on each flow.

## Carried forward from the August spec

These still hold:

- **Immutability and stamping.** Offer versions are append-only and immutable,
  enforced in the database. Every charge stamps the offer version and terms it
  was sold under. Lifecycle steps read the stamped terms: refunds "resolve
  backwards, not forwards".
- **Absence is not zero.** If no offer resolves, refuse; never charge $0 by
  default. Every tenant always resolves to some offer from the platform tenant.
- **PriceOps never moves money.** It decides what is owed; Stripe moves the
  money and is the truth for it.
- **Stripe rules:**
  - direct charges on the seller's own Stripe account (see "Decided with
    perigrin");
  - `application_fee_amount` is omitted, never 0;
  - fractions versus percentages to at most 4 decimal places;
  - `proration_behavior: 'none'` on modifications;
  - the Accounts v2 settings recorded there are one-way doors.
- **Schema and tenancy:**
  - tables about the platform tenant's customers (tenants, and what they hold
    from the platform) live in the `registry` schema, as any tenant's customer
    tables live in its own; code reaches them fully qualified, they are left
    out of `clone_schema`, and no foreign keys cross schemas;
  - payments live per tenant schema, so migrations loop over tenants;
  - one schedule phase is in effect at a time, by exclusion constraint.
- **Refunds are per entitlement**, never the whole cart. A `pending` refund is
  not terminal.
- **Revenue share comes only through Stripe.** Offline sales earn nothing for
  now (#410).
- **The launch rate:** Solo at $0 plus 2.5%, marked by
  `metadata->>'launch_rate'` and read from the database in tests.

## What this drops from the August spec

- **"Entitlement" as the price resolver** (`PriceOps::Entitlement->quote`). The
  resolver is a quote; an entitlement is the held fact.
- **The system choosing the lowest-total plan.** The customer accepts a specific
  offer. Early-bird and sibling rules become distinct offers or offer conditions
  the customer can see.
- **The payment form fused into a component's `cadence`.** Payment is a policy
  offering one or more plans.
- **The CLI as the author of platform plans,** and the `audience` split between
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
step needs somewhere for the platform's offers to live. The identity-check
exemptions noted in the memory become entitlements:

- `SendNotifications.pm:162`
- `Payment.pm:341,374`
- `PricingPlanBasics.pm:61-68`

Structural `slug <> 'registry'` checks (schema housekeeping, not business rules)
stay.

## Order of work

Each step leaves `main` releasable with the suite green.

1. **The platform as a real tenant** (#294/#265), with exemptions turned into
   entitlements.
2. **Resources, offers with policies, and entitlements as first-class data,**
   alongside today's tables. Offer versions keep the immutability triggers that
   `pricing-plan-versions.sql` already has.
3. **The product design workflow steps** that publish offers and policies, used
   first by the platform tenant for its own plans. That retires the CLI path and
   the shared-platform-plan workaround.
4. **Lifecycle steps** (accept and pay, use, change, refund, expire) that read
   the stamped policies.
5. **After-school re-expressed:** enrollments as entitlements, drop and transfer
   as the refund and change policies. This fixes the drop-approval and transfer
   defects at the root.
6. **Workflows as entitlements:** tenants hold entitlements to run workflows
   instead of copies, so new workflows reach existing tenants.
7. **Metering** for email sends, workflow runs and, later, AI tokens, recorded
   whether priced or not. The email send cap becomes an entitlement check on
   that meter.

In-studio bookings needs steps 1–4 and builds its own product on them. Steps
5–7 can follow, or run alongside in-studio work, in whatever order the launch
needs.

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
  step 5 replaces the old path rather than coexisting with it.

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
  it too: `TenantProcessor.pm`'s `slug ne 'registry'` filter goes, so the
  nightly jobs cover the platform tenant. Migrations keep their
  `slug != 'registry'` loops, because each one changes `registry` first
  (`SET search_path TO registry`) and the loop reaches every other tenant
  once; that is not an exclusion.
  The platform's sales to tenants are ordinary entitlements in its own schema.
  `registry.pricing_relationships` becomes, or is replaced by, that entitlement
  table rather than a special case.
- **Direct charges: each tenant owns its customers.** Every sale is charged on
  the selling tenant's own Stripe account (tenants connect Standard accounts,
  `StripeConnect.pm:17`), so the customer, payment method, refunds and disputes
  live there, and the platform takes its share as `application_fee_amount`.
  The code makes destination charges today (`Payment.pm:357-359`, and
  `transfer_data` on instalment schedules at `Payment.pm:142`); moving to direct charges is launch work,
  done before the first real sale because no customers or payment methods
  exist yet to move.
- **Tamarou operates the platform tenant, and Tamarou's Stripe account is its
  account.** That account is also the Connect platform account, so the revenue
  share (the application fee on every tenant's sale) and the platform
  tenant's own sales to tenants both land there. The payment steps are shared:
  each tenant record names the Stripe account its sales settle to, and the
  platform tenant's is Tamarou's. A sale that settles to the platform account
  itself needs no transfer, which follows from the account, not from a check
  for the platform tenant.
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

These came up in the builder review; each is *(my call)*.

- **Exemptions move with entitlements.** Step 1 only collapses the platform
  into one tenant. Turning the identity-check exemptions into entitlements
  happens in step 2, when entitlements exist.
- **Bootstrap.** Every tenant, the platform included, starts with seeded
  entitlements: the platform tenant's own default offer, granted at tenant
  creation, which "absence is not zero" requires anyway. The platform tenant's
  first entitlements, including the one to run product design, are seed data.
  The root has to start somewhere, and everything after it goes through
  workflows.
- **The minimum shapes for the first slice** (what in-studio needs from
  steps 2–4):
  - a finite, discrete resource (seats in an occurrence) with offers that use
    N seats each;
  - a one-time payment plan;
  - a refund policy of "none" or "full, until a cutoff";
  - a change policy of window (hours before the occurrence held), fee, and
    targets limited to occurrences of the same offer;
  - expiry at the end of the occurrence;
  - use as optional attendance.

  Instalments, recurring contracts and metered entitlements are re-expressed
  later, in steps 5–7.
- **"Offer" is already used by the waitlist** (`Waitlist.pm`,
  `accepted_offer_ids`). In this model a waitlist offer is a time-limited hold:
  a discrete entitlement with an expiry policy. The waitlist's term is renamed
  to "hold" when step 5 reaches it.
- **Tenant-edited workflows.** No tenant-facing workflow editor exists, so
  there are no tenant edits to preserve when step 6 swaps copies for
  entitlements. Verify with a query across tenant schemas before step 6.

## What's left to the builder

- Table and column design for resources, offers, policies and entitlements,
  within the rules above.
- Whether existing `pricing_plans` rows, which are configuration only, are
  converted to offer versions or re-entered through product design.
- How the lifecycle steps are grouped into workflows.
