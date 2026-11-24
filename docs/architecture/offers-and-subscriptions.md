# Offers and Subscriptions

## Overview

Registry is a marketplace that sells to its tenants the way its tenants sell to
parents. The same transaction happens at two scales, and recognising that they
are one pattern explains several things that otherwise look like separate
puzzles.

```
Alex defines offers          ->  Jordan subscribes  ->  becomes a tenant
Jordan and Morgan define offers  ->  Nancy accepts      ->  becomes enrolled
```

Nothing about either link is permanent. An offer is a thing on sale; a
subscription is a record of who took it. Both can change.

## The pattern

### At the platform scale

Alex defines the platform's offer to tenants as a published version in
`registry.offer_versions` for the resource "payment processing" -- today Solo
v1: $0 plus a 2.5% `percentage_of_sales` payment plan, with a refund policy of
`keep_fee_with_admin_exception`. The signup page still quotes plans from
`registry.pricing_plans`, where Studio and Empire are marked `coming_soon` and
refused server-side.

Jordan subscribes by completing tenant signup. Provisioning grants his tenant
an entitlement in `registry.entitlements` to that offer version and payment
plan, in effect from that moment. The entitlement is the source of his rate:
`Registry::PriceOps::PlatformTerms::platform_terms_for_tenant` reads the
tenant's in-effect platform entitlement to payment processing and returns the
version, the payment plan and its rate as an exact decimal string ("0.025").
A tenant with no entitlement in effect is refused by name. There is no
fallback to Free or to 0.

Each of his parents' payments stamps the offer version and payment plan it was
charged under (`payments.platform_offer_version_id`,
`payments.platform_payment_plan_id`). A refund reads the refund policy of that
stamped version, not his current one.

### At the tenant scale

Jordan and Morgan define their offers as sessions carrying pricing plans.
Nancy accepts one by enrolling, and pays.

### Where the platform's money actually comes from

**Nancy's acceptance, not Jordan's.** The 2.5% is an `application_fee_cents` on
her payment, taken through Jordan's Connect account as the money passes. The
platform is paid out of tenant transactions.

This is why Jordan's own card is irrelevant under revenue share, and it is the
substance of #365: the signup funnel still collects a card, because it was
built when a monthly subscription was the revenue event. Under revenue share
that acceptance never produces a charge.

## What the pattern explains

**Why a tenant's platform entitlement needs a switch path (#277).** It is a
subscription, not a stamp: its in-effect range can end and another can start.
The database allows only one in effect at a time
(`platform-entitlement-one-in-effect`). There is no path that moves a tenant
today only because there has never been a second buyable offer to move
between -- not because moving is forbidden.

**Why `coming_soon` is more than a marketing state.** With one buyable offer,
nothing has ever needed to move a tenant between offers, so no code does.
Launching Studio makes #277 a prerequisite rather than a nicety.

**Why revenue reporting reads oddly (#263).** `_get_usage_data` aggregates
`registry.payments` to compute what a tenant owes the platform. Under revenue
share the platform is already paid at charge time, from the other scale
entirely.

## Vocabulary

The code names the same ideas differently at each scale, which is part of why
the issues above read as unrelated:

| concept | in the code |
|---|---|
| a platform offer | `offer_versions` row + `offer_version_payment_plans` row |
| a tenant offer | `pricing_plans` row |
| a tenant's subscription to a platform offer | `entitlements` row (in effect) |
| the platform terms a payment was charged under | `payments.platform_offer_version_id` + `platform_payment_plan_id` |
| a parent's acceptance of a tenant offer | `enrollments` row + `payments` row |

## Where the seams are tested

Both scales are covered as browser journeys, deliberately as relays rather
than as isolated steps, because the claim is that one party's output is the
next party's input:

- `t/playwright/tenant-team.spec.js` -- Alex's offer, Jordan's subscription,
  and whether the tenant he receives is one his team can work in
- `t/playwright/lifecycle.spec.js` -- Morgan's offer, Nancy's acceptance, and
  Amara teaching what was sold

The per-persona specs beside them (`morgan`, `nancy`, `jordan`) each seed the
world they need, which is what makes them readable alone and also why none of
them can prove a seam.
