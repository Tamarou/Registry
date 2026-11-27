# After-School and Camp on PriceOps

**Status:** Draft for perigrin's approval
**Date:** 2026-11-27
**Spec step:** Step 8 of `docs/superpowers/specs/2026-11-21-priceops-model-design.md`
(branch `docs/priceops-model-design`), "After-school, re-expressed"
**Decided in:** https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5

## Intent

SACP sells after-school and summer camp today on Sawyer, and in-studio
classes through Registry, which runs on PriceOps since day one. This step
moves after-school and camp onto the same model. They are sold as offers
with published versions. A purchase is an entitlement held by the child and
paid for by a parent. Payment plans, policies and conditions carry every
pricing rule. Afterwards there is one model for every product, camp
checkout can open in production, and the old path (sessions as priced
things, `pricing_plans`, `enrollments`, the old waitlist and the old
drop/transfer workflows) is deleted.

Nothing has been sold through the old path. Production has no studio
tenants, and the SACP seed holds only two draft programs. The old path is
replaced, not run alongside.

## The rule this design follows

**Every pricing and lifecycle rule is configuration on the offer version,
never code.** perigrin's words came at each turn: "Needs to be configurable
via PriceOps", "that depends on the policy", "assuming it's in the pricing
model".
- Each rule is a payment plan, a policy or a condition on the version.
- The entitlement stamps them when it is bought.
- Later versions change only what later buyers get.
- Registry has no built-in sibling rule, transfer rule or missed-payment
  rule. It evaluates what the stamped version says.

## Goals

- **Camp and after-school are sold as PriceOps offers.** Camp checkout
  opens in production, and the `camp_checkout_refusal` guard in
  `WorkflowSteps/Payment.pm` goes.
- **Child-held entitlements.** An entitlement is held by the child
  (`holder_family_member_id`) and paid by the parent (`payer_user_id`).
  Several children in one checkout share one payment through
  `payment_share_cents`.
- **Instalment plans** are a payment-plan kind beside `one_time`.
- **New policies and conditions,** each configurable per offer version:
  - **Policies:** missed payment, waitlist, approval for refunds and
    changes, transfer targets and price difference, and make-ups.
  - **Conditions:** sibling and early-bird.
- **Every screen that reads the old model is rewired onto entitlements,**
  then the old path is retired (tables, DAOs, workflows, jobs and tests).
  perigrin: "Rewire them all onto entitlements". The screens are:
  - the parent dashboard (children's bookings, attendance, payments and
    waitlist)
  - the admin dashboard (program overview, counts, revenue, waitlist
    management, and the approval queue for drops and transfers)
  - message recipients (`DAO/Message.pm`)
  - notification and confirmation emails, including waitlist offers
  - the storefront's program listing
  - the teacher attendance view
  - `GenerateEvents`
  - the attendance-check job

## Non-goals

- **Metering.** That is spec step 9.
- **Day packs**, where a parent buys a number of days and uses them later.
  perigrin: a session is bought whole ("A").
- **Pro-rata refunds,** unless a refund policy kind is added for them later.
- **The Claude connector** (`01a213a2`). It reads whatever this step
  produces.

## Anti-goals

- **A built-in sibling, early-bird, transfer or missed-payment rule** in
  code. These are always the stamped version's configuration.
- **Running old and new paths side by side.**
- **A price that changes on an existing entitlement.** Conditions and
  policies are stamped at purchase and never re-evaluated. The one exception
  is a transfer, which follows the stamped change policy.

## The model

### What is bought

A **session** is a studio-configured span of N days: a camp week, a short
camp, or an after-school term. perigrin: "A session is a configurable number
of days", bought whole.
- Each session becomes **one finite resource** whose capacity is the
  session's capacity.
- An offer version covers that resource.
- Buying it gives the child **one unit** (a seat) for the whole session.
- The days inside the session are the session's events. Attendance and
  make-ups are tracked per day (see Uses).

Product design gets a session mode. The studio creates a program, adds
sessions (dates, days and capacity), and publishes an offer version per
session or per set of sessions. The in-studio class setup is the model
(`in-studio-class-setup`, `PublishOfferVersion`).

### Payment plans

An offer version lists one or more payment plans, and the parent picks one
at checkout.
- **`one_time`** already exists.
- **`instalments`** is new. Its fields:
  - `count`
  - `cadence`: weekly, monthly or quarterly. Weekly was added by perigrin.
  - `surcharge_pct`, which is optional.
  - It is billed with a Stripe subscription schedule on the studio's own
    account, with Solo's fee on each payment as `application_fee_percent`.
    This reuses the existing schedule code (`Payment.pm` instalment path,
    the `InstalmentSchedule` and `InstalmentReconcile` jobs, and the
    `payments.instalment_*` columns), keyed to the offer version instead
    of `pricing_plans`.
  - The first instalment is charged at checkout and grants the entitlement.
- perigrin: "Installment plans need to be a way to satisfy an offer in
  PriceOps."

### Policies (stamped per entitlement)

| Policy | Kinds / fields | Notes |
|---|---|---|
| `missed_payment` | `keep_and_owe` · `end` · `grace {days}` | Required only when an instalment plan is offered. It applies after Stripe's final retry fails. `keep_and_owe` keeps the entitlement, marks it past due, alerts admins and sends the payer a pay link. `end` ends it and frees the seat. `grace` keeps it for N days and then ends it. |
| `refund` | the existing kinds, plus `approval: required \| none` | Drops are refund requests. With approval required, the policy computes the outcome and an admin approves or declines; only approval refunds. |
| `change` | the existing window and fee, plus `targets`, `price_difference` and `approval` | `targets`: `same_offer` (today), a list of offers, or `same_program`. `price_difference`: `charge_and_refund` · `charge_only` · `same_price_only`. `approval` as for refund. Transfers are change requests. |
| `waitlist` (set on the session resource, not the version) | `none` · `queue {offer_hold_hours}` | A first-come queue per session resource. Every price for a session (regular, sibling, early-bird) shares the session's one waitlist setting, so they cannot disagree. When a seat frees, a hold for the next child is placed for N hours and the family gets a checkout link. On lapse, the seat goes to the next child. |
| `use` | the existing `optional_attendance`, plus `makeup {offer_id, credit_days, max_per_term?}` | An absence recorded by the teacher grants the child a make-up credit: a $0 entitlement to the named make-up offer (an in-studio class), in effect for `credit_days`. Staff book the child into a make-up occurrence with the credit, which takes a seat like any booking. perigrin: "They're supposed to call ahead". |

### Conditions (who may choose a version)

| Condition | Meaning |
|---|---|
| `family_holds_entitlement {offer_ids?}` | Already stored; now evaluated. Another child in the payer's family holds an active entitlement, bought earlier or earlier in the same checkout. `offer_ids` limits which offers count; leaving it out means any offer at the studio. perigrin confirmed that a sibling added a month later gets the rate, and that which enrollments qualify is configuration. |
| `before {at}` (new) | The version can be chosen only until `at`. This is early-bird. |

The sibling and early-bird prices are **separate offer versions** of the same
offer, each with its condition. At checkout, the parent sees the versions
whose conditions the child meets, with the cheapest preselected. This
replaces `PricingPlan->best_plan`. A price is always a published version.

### Uses and attendance

- `entitlement_uses` gains an **absent** mark beside present.
- Teachers mark attendance for a session day in an attendance view. It is
  the in-studio day view extended to sessions, or the teacher dashboard
  rewired to entitlements. `attendance_records` goes.
- The `attendance_check` job reads entitlements and uses instead of
  enrollments.

### Terms

Camp and after-school take the `/terms` agreement exactly as in-studio does.
The agreed version is recorded on each entitlement (`terms_version`).

## How it gets built (approach)

perigrin chose: **one milestone, both products together** (option 2 of 3).

| Approach | Trade-off | Chosen? |
|---|---|---|
| One milestone, camp first, then after-school, then delete the old path | Ships camp early; more PRs | No |
| **One milestone, both products together** | Fewer PRs; nothing ships until all of it lands; larger PRs to review | **Yes** |
| Keep the old path for after-school | Smaller now; breaks "no product launches on today's pricing tables" | No |

The milestone runs as day one did: git-zhi chain, test-first issues, TIER_2
gates on money, security and schema, and full suite plus CI before each PR.
perigrin merges.

## Decided by perigrin (this conversation)

1. Instalments are a payment plan that satisfies an offer.
2. What happens on a missed instalment is configurable per offer (the
   `missed_payment` policy).
3. Instalment cadence is weekly, monthly or quarterly.
4. A session is a configurable number of days, bought whole.
5. A sibling added later gets the sibling rate; which enrollments qualify is
   configuration.
6. Drops and transfers keep an admin's review. The policy computes the
   outcome and an admin approves; approval is a per-policy setting.
7. A transfer to a different-price session charges or refunds the
   difference, as the change policy says.
8. Waitlist: the next child in line gets a held seat.
9. Make-ups: the teacher marks the absence, and the family attends a
   make-up class at the studio, booked ahead.
10. Both products in one milestone.

11. Every screen that reads the old model is rewired onto entitlements in
    this milestone ("Rewire them all onto entitlements").

## Calls made by the designer (flagged for review)

These came from the builder check.
- **Siblings on instalments.** Each child's entitlement has its own plan
  choice and its own Stripe schedule. The first instalments of every child
  in a checkout are combined into one charge, so the parent pays once at
  checkout. A missed payment, drop or transfer acts on that child's
  schedule alone. One checkout may mix one-time and instalment children.
- **Drops on instalments.** The refund policy's outcome is computed on the
  amount paid so far. An approved drop cancels the remaining instalments.
- **Waitlist placement.** The waitlist setting lives on the session
  resource, not on each version (see Policies).
- **Make-ups.**
  - Every absence the teacher marks earns a credit, limited by
    `max_per_term` if it is set.
  - Registry grants the credit directly as a $0 entitlement to the make-up
    offer, held by the child and linked to the absence. It is not a checkout.
  - Staff book make-ups; parents call ahead.
- **Missed payments.**
  - `missed_payment` acts on Stripe's final failed retry of an instalment
    invoice.
  - Under `keep_and_owe`, later instalments keep billing, and the pay link
    covers the missed invoice only.
  - Under `grace`, paying within the N days restores the entitlement to
    active.
  - Studios must set Stripe's retry outcome to leave the subscription past
    due. This goes in `docs/operations/sacp-stripe-connect-onboarding.md`.
  - If Stripe cancels a schedule anyway, Registry alerts the studio's
    admins and changes nothing on its own.
- **Sibling qualification.** A qualifying entitlement may be active or past
  due, at the same studio. Studios are separate tenants, so no other studio
  is visible.

- **Sibling and early-bird conditions are stamped and kept.** A sibling who
  bought at the sibling rate keeps it if the older child later leaves;
  nothing is clawed back, consistent with the referral ruling. A qualifying
  entitlement must be active at the moment of purchase.
- **A transfer of an instalment-paid entitlement settles the difference
  against the remaining instalments**, not as a lump sum now.
- **A waitlisted family pays the version in effect when the seat is
  offered,** and picks its payment plan then.
- **Early-bird is a `before {at}` condition** on its own version, not a
  timed price change.
- **`missed_payment` is required** on any version that offers instalments,
  so the outcome is never left unspecified.
- **Approval stays off for in-studio offers,** so today's behaviour is
  unchanged.

## Left to the builder

- Table and column shapes: the `instalments` plan fields, the waitlist
  queue table, the absent mark, the make-up credit's link to its absence,
  and the session resource's link to its events.
- Weekly cadence over a short camp: refuse or clamp an instalment plan
  whose last payment would fall after the session ends. Choose and
  document.
- How totals across locations in different time zones are shown. This is
  also open in the connector decisions; SACP has one location.
- Retirement order and the list of old tests to delete or rewrite. About
  200 test files mention the old model by keyword.
- The registry storefront's "Get Started Today" session (seeded in
  `seed-registry-storefront-v2.sql`), and the two SACP draft projects in
  `sql/seed/sacp-tenant.sql`. Re-express them as PriceOps offers, or remove
  them.
- Fixing the admin decision workflows that don't advance today
  (`ProcessAdminDropDecision` uses `new_run`). The new approval steps should
  continue runs through `ContinueWorkflowRun`.

## What exists to build on (main 6101fd1)

- **Entitlements:** one-holder check incl. `holder_family_member_id`,
  `payer_user_id`, `payment_share_cents`, units, holds, uses and
  `entitlement_refunds`.
- **Offer versions:** policies (refund, change, use, expiry), stored
  conditions, payment plans `one_time` / `percentage_of_sales`, and the CHECK
  in `priceops-offer-policies.sql` that a new kind extends.
- **Workflows:** `entitlement-refund`, `entitlement-change`,
  `entitlement-stripe-move`, and the `ContinueWorkflowRun` driver.
- **Stripe:** direct charges and subscription schedules on the studio's
  account, with the application fee.
- **In-studio pieces to reuse:** the hold, booking, day view and
  record-use flow, and the class-setup and offer-publishing workflows.
