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

The model behind both scales (resources, offer versions, entitlements and
payments, and the rules they follow) is described in
[PriceOps Model](priceops-model.md). This document covers only how the two
scales line up.

## The pattern

### At the platform scale

Alex publishes the platform's offer to tenants as an offer version in
`registry.offer_versions`: today Solo v2, $0 plus a 2.5% `percentage_of_sales`
payment plan, whose resource set grants payment processing and the run right to
every shipped workflow. Jordan subscribes by completing tenant signup, which gives his
tenant an entitlement to that version in `registry.entitlements`. That
entitlement is the source of his rate. See
[The platform is just a tenant](priceops-model.md#the-platform-is-just-a-tenant).

### At the tenant scale

Jordan and Morgan define their offers as sessions carrying pricing plans.
Nancy accepts one by enrolling, and pays. After-school moves onto offer
versions and entitlements in step 8 of the PriceOps order of work.

### Where the platform's money actually comes from

**Nancy's acceptance, not Jordan's.** The 2.5% is an `application_fee_amount`
on her payment, taken on Jordan's own Stripe account as the money passes. The
platform is paid out of tenant transactions.

## What the pattern explains

**Why a tenant's platform entitlement needs a switch path (#277).** It is a
subscription, not a stamp: its in-effect range can end and another can start.
The database allows only one in effect at a time. There is no path that moves
a tenant today only because there has never been a second buyable offer to
move between, not because moving is forbidden.

## Vocabulary

The code names the same ideas differently at each scale, which is part of why
the issues above read as unrelated:

| concept | in the code |
|---|---|
| a platform offer | `offer_versions` row + `offer_version_payment_plans` row, in `registry` |
| a tenant offer | `pricing_plans` row (after-school) |
| a tenant's subscription to a platform offer | `registry.entitlements` row, in effect |
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
