# PriceOps model — design

Status: draft for perigrin's review. Base: `main` at 4e6664b. This design
supersedes the model sections of
`docs/superpowers/specs/2026-08-07-priceops-alignment-design.md` (the "August
spec") where the two conflict. It keeps the August spec's money and schema rules
(see "Rules that hold"). The in-studio bookings product is step 7 of this
design's order of work. The earlier in-studio draft
(`docs/in-studio-bookings-design` branch) predates this model: it assumes
destination charges, a per-tenant fee, required extras and building on
`finalize_enrollment`. It is rewritten on top of this model before step 7
starts, and where the two disagree, this one wins.

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
- acting as another tenant (the operator right, see "The platform tenant made
  real");
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
    - a percentage of each of the holder's own sales, collected on each sale.
      This is the platform's revenue share; it has no period and is never
      invoiced;
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

- the holder: a person for a studio's sale, a tenant for the platform's;
- the exact offer version, and so the exact policies it was sold under;
- when it is in effect (Pillar 2's schedule "phase");
- for a discrete entitlement, the specific units it holds (the seats in this
  occurrence);
- for a metered entitlement, the consumption recorded against it.

The holder is who the entitlement is for, which need not be who paid: an
after-school entitlement is held for a child and paid for by a parent. The
sibling condition reads holders, so step 3's table must allow a holder who is
not the payer.

An entitlement's life (**used, changed, refunded, expired**) moves only through
its offer version's policies, or is settled from Stripe, which the policies do
not gate (see "Decided with perigrin"). No step carries its own refund, transfer
or expiry rule.

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
- in arrears for metered use;
- on each of the holder's own sales, for a percentage-of-sales plan.

A tenant's take is shaped by the platform tenant's offer to that tenant. The
revenue share is a term of the offer SACP accepted from the platform, not a
special calculation. Today the charge-time rate is read from
`registry.tenants.platform_pricing_plan_id` (`RevenueShare.pm:37-55`), while
`registry.pricing_relationships` only backs the signup menu; under this model
the tenant's entitlement from the platform is the one source, and both of
those give way to it in step 3.

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

Who may run which workflow is data too. Today it is the hard-coded
`workflow_roles` map in `Registry.pm`, and the gate is open by default: a slug
with no entry has no guard (`Registry.pm:714`). Until step 6 makes the map
data, every workflow a step adds gets an entry, and a test fails if any
imported workflow has neither an entry nor a deliberate "public" mark.

Workflow steps name Perl classes. `CreateWorkflow.pm:55` takes the class from
the submitted form and `WorkflowStep.pm:84-85` loads it with `eval require`,
with no check in between. Every tenant already holds `workflow-creation`
(`Tenant.pm:873-882`), open to its `admin` and `staff`, so today a tenant's
staff member can name any class for the shared process to load. Step 0 closes
this: step classes come from a server-side allowlist, and a tenant composes
allowed steps, never names code.

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
- the operator right (acting as another tenant, the job queue, the
  cross-tenant revenue view), held only by the platform tenant;
- in future, AI tokens.

Whether any of these is included in an offer or metered per use is the platform
tenant's product design choice, like any tenant's. The model supports both.
The business rule carried from the pricing strategy still guides that choice:
**never gate features that help customers make money.**

**On day one the platform sells exactly one offer: Solo, $0 plus 2.5% of each
sale.** There is no paid subscription tier. Studio and Empire, which exist as
plans today, are not published.

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
| payment policy | one-time; instalment schedules (#425, `pricing_configuration.schedule`) | one policy offering one or more of these plans |
| entitlement | an enrollment tied to one child, plus the payment stamp | an entitlement held for the child, referencing the offer version |
| refund policy | the drop flow and `ProcessDropRefund` | a policy on the offer, applied by a lifecycle step |
| change policy | the transfer flow: admin-approved, no lock, no money | a policy on the offer (window, fee, targets), applied with locks and payment |
| use policy | attendance; SACP's make-up within a month of a missed class | stated as the offer's use policy; a make-up is a fee-free right to use another occurrence, triggered by a missed one |
| expiry | nothing | stated: an occurrence-bound entitlement expires when its occurrence ends |

(`Subscription.pm` is not after-school: it is the platform's billing of
tenants, covered in step 5.)

Today's drop and transfer defects share one cause: nothing runs a workflow's
later steps without a person at the screen.
`Registry::WorkflowProcessor->new_run` processes only the first step
(`Utility/WorkflowProcessor.pm:9-14`), so drop approval never advances and
transfer never reaches its `ValidateTargetCapacity` step. The job that looks
like a driver (`Job/WorkflowExecutor.pm`) starts a new run from the first step
instead of continuing a parked one, and is never registered. Transfer also
moves no money, and its capacity check is an unlocked count; re-expressing
drop and transfer as policies fixes that. The driver is needed by every
lifecycle step (refund, change, expire) and is its own piece of work in step 5.

## Rules that hold

Most of these come from the August spec. They are rules for the build, not a
description of today's code; where the code does not yet follow one, the rule
says so.

- **Immutability and stamping.** Offer versions are append-only and immutable,
  enforced in the database. Every charge stamps the offer version it was sold
  under and the platform offer version the fee was taken under (today
  `payments.platform_pricing_plan_id`). Lifecycle steps read the stamped
  terms: refunds "resolve backwards, not forwards".
- **Absence is not zero.** If no offer resolves, refuse; never charge $0 by
  default. Every tenant always resolves to some offer from the platform tenant.
  Today's Free plan at 0% breaks this rule and goes with all three of its
  readers: the charge-time rate (`RevenueShare.pm:49-51, 61-83`), the refund
  path (`RevenueShare.pm:177-204`) and the signup page's quoted rate
  (`TenantPayment.pm:220-237, 348-350`).
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
    (`Service/Stripe.pm:98-100`). If that moves to Accounts v2, the settings
    chosen there are one-way doors.
- **Schema and tenancy:**
  - tables about the platform tenant's customers (tenants, and what they hold
    from the platform) live in the `registry` schema, as any tenant's customer
    tables live in its own; code reaches them fully qualified, and no foreign
    keys cross schemas. `clone_schema` copies the structure of every table in
    `registry` (`fix-clone-schema-identifier-quoting.sql:359-367`), so every
    tenant schema has these tables, empty unless that tenant has customers of
    its own;
  - `registry` is also the directory: tenant resolution, the provisioning
    templates and every charge's seller lookup read it by name. It is the one
    schema shared steps may name. `Tenant.pm:22` (`sub table { 'tenants' }`)
    does not yet qualify it, so on a tenant connection it reads the tenant's
    empty copy; step 1 fixes that;
  - payments live per tenant schema, so migrations loop over tenants;
  - one schedule phase is in effect at a time, enforced by an exclusion
    constraint (none exists yet; step 3 adds it).
- **Refunds are per entitlement**, never the whole cart. A `pending` refund is
  not terminal.
- **Revenue share comes only through Stripe.** Offline sales earn nothing for
  now (#410).

## What this drops from the August spec

- **"Entitlement" as the price resolver** (`PriceOps::Entitlement->quote`). The
  resolver is a quote; an entitlement is the held fact.
- **The system choosing the lowest-total plan.** The customer accepts a specific
  offer. Early-bird and sibling rules become distinct offers or offer conditions
  the customer can see.
- **The payment form fused into a component's `cadence`.** Payment is a policy
  offering one or more plans.
- **Migrations and metadata markers as the author of platform plans** (the
  August spec planned a CLI; none was built), the `launch_rate` marker, and
  the `audience` split between revenue-share plans and the signup menu. The
  platform tenant authors its offers through the same product design workflow
  as anyone.
- **Platform pricing tables excluded from cloning** (August :933-935).
  `clone_schema` copies every table, and that is now the rule.
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

- checks against the all-zeros id (`PricingRelationship.pm`,
  `PricingPlanBasics.pm`, `PricingPlanSelection.pm`, `PricingPlan.pm`). #294
  keeps that id so the rename is one migration; these checks are removed as
  step 3 gives them data to read;
- `Tenant->platform`, which finds the platform by the slug `registry-platform`
  (`Tenant.pm:167`). The rename breaks it, so it changes in the same commit as
  the rename, or every `/platform/*` route returns 403;
- `SendNotifications.pm:162` and `Payment.pm:341,374`, which branch on the
  platform slug, become reads of the tenant's entitlements and Stripe account.

**Admin of the platform tenant means membership.** Every studio's founding
admin is created in `registry.users` and copied out (`Tenant.pm:838-842`), and
`require_role` checks `user_type` only, so "an admin user found in `registry`"
would make every founder a platform admin. An admin of the platform tenant is
a user with a `registry.tenant_users` row for the `registry` tenant and the
admin role, which is the fact `is_platform_admin` reads today
(`Tenant.pm:179-190`). `t/security/platform-admin-only.t` keeps its Morgan case
and still refuses.

**The operator right.** Three surfaces cross tenants: acting as any tenant
(`_acting_tenant_for`, `Registry.pm:1205-1230`, today open to any member of the
all-zeros tenant with no role test), the job queue (`/platform/jobs`, Minion
admin over every tenant's jobs and arguments) and the cross-tenant revenue view
(`/platform/revenue`). They become one resource, the operator right, held
by the platform tenant through an ordinary entitlement and usable only by that
tenant's admins. Other tenants' admins see the same admin screens without
these three. Acting as another tenant requires the operator right and the admin
role.

**Which `slug <> 'registry'` checks stay.** A check stays only where `registry`
has already been handled another way: a migration loop that changed
`registry` first, or a connection where `connect_schema('registry')` is the
default connection. Every other check treats the platform tenant as something
other than a tenant, and goes. (#294 keeps the `!= 'registry'` filters in
`TenantProcessor.pm`; this design does not.) Before each one goes, the job is
tested against the platform tenant. The site list lives in step 1's issue,
from a search (`ag "(ne|eq|<>|!=)\s*'registry'" lib`), not here. One site
matters beyond the rest: `Controller/Workflows.pm:107-114` drops
`__tenant_slug` when the tenant is `registry`, and the payment step refuses any
priced cart without a slug, so the platform tenant cannot sell through the
shared payment steps until it goes.

**When a seller's Stripe account is the Connect platform account.** If Stripe
refuses a `Stripe-Account` header naming the platform's own account, the shared
payment step omits the header when the seller's `stripe_connect_account_id`
equals the account the API key belongs to (read once at startup). That compares
two data values, not an identity; it is not a platform check. Day one does not
exercise it, because the platform makes no card sale.

## Order of work

Each step leaves `main` releasable with the suite green. Steps 2 and 4 each
touch 20 to 40 test files and land as several issues.

0. **Green CI on `main`, and the step-class allowlist.**
   - CI dies at `carton install --deployment` in all three jobs (DBD::Pg,
     IO-Socket-SSL, Test::PostgreSQL), so no test has run. First restore the
     install; then a spike whose deliverable is the list of what is red; then
     make it green.
   - The step-class allowlist (see "How PriceOps is driven"), with a test that
     a submitted class outside it is refused. It is a live hole, so it does
     not wait.
1. **The platform as a real tenant** (#294/#265):
   - the rename, with `Tenant->platform` in the same commit;
   - admin as membership, and the operator right as an entitlement held by the
     platform tenant (seeded by the bootstrap until step 3's table exists);
   - the kept row's link to Solo cleared, so the platform does not charge
     itself 2.5% (both rows point at Solo in `test-schema.sql:2570-2571`);
   - `Tenant.pm:22` qualified;
   - the `slug <> 'registry'` checks handled by the rule above, including
     `Controller/Workflows.pm:107-114`;
   - the bootstrap root writes Tamarou's Stripe account id and readiness flags
     onto the `registry` row, and the first admin's email address, both from
     deployment configuration as `STRIPE_SECRET_KEY` is. Today the only admin
     the deploy creates has a dummy hash and an unreachable address, and
     `/admin/billing/connect` would mint a second Stripe account;
   - `sql/test-schema.sql` and the tests pinned to two rows
     (`t/dao/inert-tenants.t`, `t/dao/attendance-check-search-path.t`,
     `t/dao/unified-pricing-engine.t`) updated.
2. **Direct charges, with Stripe as the source of truth.** Charges, refunds
   and the payment form move to the selling tenant's account:
   - the Stripe client sends the `Stripe-Account` header per call
     (`Service/Stripe.pm` has no support for it, and `Payment.pm:403-415`
     builds the client once);
   - instalment schedules and Stripe customer creation carry the account too
     (`Payment.pm:138-149, 188-270, 476-525`);
   - refunds stop using `reverse_transfer` (`Payment.pm:362-383`);
   - the fee is kept on a refund by default; today the code refunds it by
     default (`RevenueShare.pm:209-212`, `refund-application-fee-config.sql`,
     `Payment.pm:376-380`, `t/dao/refund-application-fee.t`). The exception
     is an application-fee refund call, which `Service/Stripe.pm` lacks, and
     what was kept is updated from `application_fee.refunded`;
   - `Payment.pm:341,374` branch on the account, as above;
   - the browser's Payment Element is given the tenant's account;
   - `application_fee_amount` is omitted at 0;
   - a Connect webhook endpoint, with its own secret, reads `event.account` to
     find the tenant instead of metadata. Every payment event moves there,
     including the `payment_intent.succeeded` that completes a sale. Refund,
     dispute and customer events are verified and stored; step 5 applies
     them. An event for a payment Registry did not make (a studio's own
     Terminal or counter charge) is answered 200, logged and ignored;
   - the tests that pin destination charges are rewritten;
   - the builder checks in test mode whether a charge on the Connect platform
     account itself accepts a `Stripe-Account` header naming that account;
   - the Alex persona (`docs/personas/alex.md`), which says paid enrollment
     is live on destination charges, is updated.
3. **Resources, offers with policies and conditions, and entitlements as
   first-class data.**
   - Offer versions keep the immutability triggers that
     `pricing-plan-versions.sql` already has.
   - The entitlement holder allows a person, a child held for by a parent,
     or a tenant.
   - `RevenueShare.pm` reads the tenant's entitlement from the platform;
     `tenants.platform_pricing_plan_id` and `registry.pricing_relationships`
     are dropped in the same step, so the two are never both in force.
   - Every tenant whose row names a platform plan gets the matching
     entitlement. SACP has none (it was created by `sql/seed/sacp-tenant.sql`,
     with its Stripe account written by hand), so it accepts Solo once in
     step 5.
   - The identity checks above read entitlements from here.
4. **The product design workflow steps** that publish offers and policies.
   Both day-one users run them: the platform tenant publishing later versions
   of Solo, and SACP publishing its in-studio offers. Only admins of a tenant
   may publish its offers; `pricing-plan-creation` loses `staff`. That retires
   the migrations and the `launch_rate` marker that author platform plans
   today.
5. **Lifecycle steps** (accept and pay, use, change, refund, expire) that read
   the stamped policies.
   - **Tenant signup is the platform's accept-and-pay.** Signup lists the
     platform's published offer versions (on day one, only Solo, preselected),
     and accepting one creates the entitlement. That replaces
     `TenantPayment.pm`'s plan lookup and its card collection, the Stripe
     subscription path in `Subscription.pm`, the "tenant billing" fallthrough
     in `Webhooks.pm:172-181`, and the mock subscription written when no keys
     are set. The billing columns on `registry.tenants`
     (`stripe_customer_id`, `stripe_subscription_id`, `billing_status`,
     `trial_ends_at`, `subscription_started_at`) go with it.
   - **Change holds the target first.** A move takes the target seat as a
     time-limited hold, then charges the change fee; if the charge fails or
     the hold lapses, the hold is released. The fee is never refunded by the
     system, because it is only taken once the seat is held.
   - **Stripe-reported moves** stored in step 2 are applied: a full refund
     ends the entitlement and frees its resources, a partial refund is
     recorded, a lost dispute ends it.
   - **A driver for steps no person is waiting on**, sized as its own unit. It
     takes the tenant schema and the run id in the job's arguments, continues
     the parked run rather than starting a new one, passes each step's data on,
     is safe to retry for any step that moves money (Minion runs it up to three
     times), and says what a half-finished run means. `Job/WorkflowExecutor.pm`
     does none of this today.
   - **Recurring jobs that recur.** `setup_recurring_jobs`
     (`Registry.pm:1351-1442`) enqueues each job once per server start. The
     expiry job and the existing sweeps re-enqueue themselves or run on a
     schedule, with a test that proves a second run happens.
   - The old after-school drop and transfer flows are left alone until step
     8 replaces them.
6. **Workflows as entitlements.** A tenant's right to run a workflow comes
   from an entitlement, so new workflows reach existing tenants by offer. This
   is how in-studio booking reaches SACP's existing schema, so it comes
   before step 7. Who may run which workflow becomes data here, with the
   gate refusing a workflow that has no entry. Before any tenant copy is
   replaced, the step lists tenant workflows whose slug, steps, classes or
   templates differ from the platform's and reports them to perigrin.
7. **In-studio bookings** on this model, from the rewritten draft: class setup
   and occurrence generation as product design; the booking page; one adult
   booking N seats (capacity today keys on `family_members`); the staff day
   view; `/terms`; Secure cookies; refusing payment when the tenant's Stripe
   key is missing. The 48-hour change window is measured in the studio's time
   zone (`events.time` carries none today).
8. **After-school re-expressed:** enrollments as entitlements held for the
   child, drop and transfer as the refund and change policies, sibling
   discounts as offer conditions, the make-up as a use policy, before
   after-school sells anything.
9. **Metering** for email sends, workflow runs and, later, AI tokens, recorded
   whether priced or not. The email send cap becomes an entitlement check on
   that meter.

**Day one is steps 0–7:** the platform selling Solo to tenants and SACP's
in-studio offers both live. Step 8 follows before after-school sells. Step 9
can follow after that.

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
  step 8 replaces the old path rather than coexisting with it.
- Extras sold with a booking. They go through the studio's point of sale.

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
  it too, and recurring jobs cover the platform tenant. Migrations keep their
  `slug != 'registry'` loops, because each one changes `registry` first
  (`SET search_path TO registry`) and the loop reaches every other tenant
  once; that is not an exclusion.
  The platform's sales to tenants are ordinary entitlements in its own schema.
  That entitlement table replaces both `registry.pricing_relationships` and
  `tenants.platform_pricing_plan_id` as the record of what a tenant holds.
- **Direct charges: each tenant owns its customers.** Every sale is charged on
  the selling tenant's own Stripe account (tenants connect Standard accounts),
  so the customer, payment method, refunds and disputes live there, and the
  platform takes its share as `application_fee_amount`. The code makes
  destination charges today (`Payment.pm:357-359`, and `transfer_data` on
  instalment schedules at `Payment.pm:142`). Moving to direct charges is step
  2, done before the first real sale because no customers or payment methods
  exist yet to move.
- **Tamarou operates the platform tenant, and Tamarou's Stripe account is its
  account.** That account is also the Connect platform account, so the revenue
  share (the application fee on every tenant's sale) and the platform
  tenant's own sales to tenants both land there. The payment steps are shared:
  each tenant record names its Stripe account, and the `registry` row names
  Tamarou's. Every tenant holds a revenue-share offer from the platform; the
  platform tenant's offer from itself is an explicit 0%, so its own sales send
  no `application_fee_amount` by the ordinary "omitted, never 0" rule rather
  than by a check for the platform.
- **Alex administers the platform tenant.** The persona Alex
  (`docs/personas/alex.md`, which replaced Alice in 08c3a5a) stands in for
  perigrin and Tamarou: an admin of the `registry` tenant by membership, using
  the same admin screens and workflows as any tenant's admin. The `/platform/*`
  screens, the `registry platform` CLI and `is_platform_admin` become that
  tenant's admin surface, not a separate one.
- **Operator tooling is an entitlement the platform tenant holds.** Acting as
  another tenant, the job queue and the cross-tenant revenue view are the
  operator right, and only admins can act as other tenants.
- **The platform's customers are tenants.** SACP and every other tenant are
  the platform tenant's customers, as organisations.
- **The only offer on day one is Solo, $0 plus 2.5%.** No paid subscription
  tier. A seeded first version of Solo is part of the bootstrap root; signup
  accepts a published offer, with Solo preselected; SACP, which predates
  signup, accepts it once.
- **Tamarou keeps its share on a refund** unless Tamarou caused the sale to be
  wrong. That is a term of the offer between the platform and the tenant, not
  of the offer the customer accepted: Solo carries a refund policy of "keep the
  fee", with an exception the platform tenant's admin applies when the fault
  is Tamarou's.
- **A change holds the target seat before charging the fee,** and releases it
  if the charge fails. No system-issued refund of a change fee exists.
- **Everything moves to the new model, and CI goes green first.** No product,
  in-studio or after-school, launches on today's pricing tables.
- **Stripe is the source of truth for money and customers; Registry follows
  it.** A refund issued in a tenant's Stripe dashboard, a lost dispute, or a
  customer changed there is applied to the matching entitlement: a full refund
  ends the entitlement and frees its resources, a partial refund is recorded
  against it, and a lost dispute ends it. These moves come from Stripe, not
  from the offer's policies, and the policies do not gate them. Registry never
  contradicts Stripe and never re-charges to undo it. Dispute fees fall where
  Stripe puts them, on the tenant as merchant.
- **The platform and SACP are both ready on day one,** and in-studio booking
  is part of day one, which pulls workflows-as-entitlements (step 6) in with
  it.
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
  of entitlements or the Stripe account in steps 2 and 3.
- **Bootstrap.** The one thing that exists before any workflow can run is the
  root: the platform tenant's row with Tamarou's Stripe account, its first
  admin (address from deployment configuration), its right to run product
  design, its operator right, and the first version of Solo. The deploy
  migration creates it, as it creates the row today. Nothing after it is
  created any other way.
- **Only tenant admins publish offers.** `staff` may run a tenant's programs
  but not publish its prices, so a `staff` user of `registry` cannot change
  what every tenant is charged.
- **The minimum shapes for day one** (what steps 3–7 must support):
  - a finite, discrete resource (seats in an occurrence) with offers that use
    N seats each, and a per-booking cap on how many of an offer one booking
    may take;
  - a one-time payment plan;
  - a percentage-of-sales payment plan (Solo), accepted at signup;
  - a refund policy of "none", "full, until a cutoff", or "keep the fee, with
    an admin exception" (Solo);
  - a change policy of window (hours before the occurrence held), fee, and
    targets limited to occurrences of the same offer. The fee is a one-time
    payment like any other, so the revenue share applies to it;
  - a time-limited hold;
  - expiry at the end of the occurrence;
  - use as optional attendance;
  - lifecycle moves reported by Stripe: full refund, partial refund, lost
    dispute.

  Instalments, metered entitlements and offer conditions arrive with
  after-school and metering, in steps 8 and 9.
- **"Offer" is already used by the waitlist** (`Waitlist.pm`,
  `accepted_offer_ids`). In this model a waitlist offer is a time-limited hold,
  the same shape a change uses. The waitlist's term is renamed to "hold" when
  step 8 reaches it.

## What's left to the builder

- Table and column design for resources, offers, policies, conditions and
  entitlements, within the rules above.
- Whether existing `pricing_plans` rows, which are configuration only, are
  converted to offer versions or re-entered through product design.
- How the lifecycle steps are grouped into workflows.
- The issue-level lists of sites for step 1's slug checks and step 2's
  rewritten tests, from a search at the time.
