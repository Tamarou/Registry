# Plan-Driven Revenue Share

Spec for GitHub issue #267 — *Derive the platform revenue-share rate from the
tenant's pricing plan, not a constant.* Folds in the relevant part of #268
(orphaned pricing-relationship seed) because the rate cannot be plan-driven
until a plan actually exists and is linked to the tenant.

Status: spec-reviewed (PAAD pushback, 2026-06-13). Base branch: `main` (#271 is
merged, so the revenue-share constant, the destination-charge path, and the
Leg 3 guard-rail test are present). Work branch:
`feature/plan-driven-revenue-share`.

**Delivered as two stacked PRs** (spec-review decision):
- **PR1 (#268):** sqitch-plan `create-default-pricing-relationships`, seed the
  Free + launch revenue-share plans, add the CI orphan-check. Pure data/deploy;
  independently verifiable; fixes the "zero selectable plans on fresh deploy"
  prod bug on its own.
- **PR2 (#267):** add `tenants.platform_pricing_plan_id` (+ backfill), the rate
  resolver, remove the constant, and take the Leg 3 `TODO` off. Stacked on PR1.

**Persistence mechanism: Option A confirmed** — a nullable FK on the tenants
row (see Data model). All pushback resolutions are folded into the sections
below.

## Background

Today the platform's revenue-share rate is a hardcoded constant. On the
`feature/alex-user-journeys` branch (#271, commit f5fb0da):

- `lib/Registry/DAO/Payment.pm` defines `use constant REVENUE_SHARE_PERCENT => 2.5`.
- `application_fee_cents($amount_cents)` computes
  `int($amount_cents * REVENUE_SHARE_PERCENT / 100 + 0.5)`.
- `_connect_params($db, $metadata, $amount)` looks the tenant up by slug, reads
  `registry.tenants.stripe_connect_account_id`, and returns the Stripe Connect
  destination-charge params: `transfer_data[destination]`, `on_behalf_of`, and
  `application_fee_amount => application_fee_cents(_to_cents($amount))`.
- `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm` re-exports the same constant
  for its signup-page display copy.

Meanwhile the seeded platform plan
(`sql/deploy/unified-pricing-infrastructure.sql`) advertises **2%**:

```
'Registry Revenue Share - 2%', 'revenue_share', 'percentage', 0.02, 'USD',
'{"percentage": 0.02, "applies_to": "customer_payments", "minimum_monthly": 0}'
```

So the rate **displayed** to a tenant (2%) and the rate **charged** (2.5%)
already disagree. The Alex Leg 3 journey test
(`t/user-journeys/alex/03-platform-billing.t`) encodes this drift as a `TODO`
assertion that compares the displayed rate to `REVENUE_SHARE_PERCENT`; it is
expected-red today and is meant to go green permanently once the rate is
plan-driven.

### Decision (perigrin, 2026-06-13)

1. **No hardcoded constant for the revenue share. Only price ops.** The rate
   must come from the pricing-plan layer.
2. **Launch rate: decide later.** Build the plan-driven architecture; flag the
   single place the rate number is seeded. The 2%-vs-2.5% choice is deferred and
   does not block this work.
3. **No-plan fallback: resolve to a default Free plan (0% revenue share).** A
   tenant with no explicit platform plan link resolves to a seeded Free plan, so
   the fee derivation stays entirely in price ops with zero magic numbers.

## Goals

- The platform revenue-share rate has **one** source of truth: a pricing plan.
- The rate shown on the signup/pricing UI and the rate charged as the Stripe
  `application_fee_amount` are derived from the *same* plan, so they cannot
  drift.
- A tenant always resolves to a plan at charge time — its linked plan, or the
  seeded Free plan (0%) — never a constant.
- Platform pricing plans are actually present and selectable on a fresh deploy
  (the #268 prerequisite), and the tenant→plan link is persisted at signup.
- `Registry::DAO::Payment::REVENUE_SHARE_PERCENT` is deleted. No equivalent
  constant survives anywhere.

## Non-goals

- Redesigning usage reporting (#263) — it reads the same pricing data and will
  benefit, but is out of scope here.
- Customer-facing (tenant→parent) pricing. This spec is strictly the
  platform→tenant revenue share.
- Choosing the launch rate number (deferred per decision 2).
- The other three orphaned SQL files in #268 (`fix-pricing-validation-trigger`,
  `resource-aware-pricing-plans`, `restructure-data-model`) — tracked
  separately; only `create-default-pricing-relationships` is in scope here
  because it gates plan selection.
- **Plan switching after signup.** `platform_pricing_plan_id` is set at signup
  and backfilled for existing tenants; no UI/flow changes the platform plan
  afterward. Out of scope here, but the invariant above must be enforced when it
  is built (tracked via a follow-up issue).

## Data model

### Existing schema (verified)

`registry.pricing_plans`:
- `id UUID`
- `plan_scope` ∈ (`customer`, `tenant`, `platform`)
- `pricing_model_type` ∈ (`fixed`, `percentage`, `tiered`, `hybrid`, `transaction_fee`)
- `amount DECIMAL(10,2)`
- `pricing_configuration JSONB` (revenue-share plans carry
  `{"percentage": 0.02, "applies_to": "customer_payments"}`)
- `metadata JSONB`

`registry.pricing_relationships`:
- `provider_id UUID` → `registry.tenants(id)` (platform = `00000000-…-000000000000`)
- `consumer_id UUID` → **`registry.users(id)`** (note: a user, not a tenant)
- `pricing_plan_id UUID` → `registry.pricing_plans(id)`
- `status` ∈ (`pending`, `active`, `suspended`, `cancelled`)

The `consumer_id`-is-a-user detail matters: the existing relationship table
links a plan to a *user*, not directly to a tenant. A tenant's authoritative
platform rate therefore can't be read from `pricing_relationships` by tenant
slug alone without going through the tenant's primary user.

### Rate representation

Revenue-share plans store the rate as a **fraction** (`0.02` = 2%) in both
`amount` and `pricing_configuration.percentage`. The display copy renders it as
`fraction * 100` ("2%"). The charge computes `fee_cents = round_half_up(
amount_cents * fraction )`. This single fraction is the source of truth for both
sides, which is what eliminates the drift by construction.

> The current constant path uses `REVENUE_SHARE_PERCENT = 2.5` then divides by
> 100 (→ 0.025). The plan path uses the stored fraction directly (→ 0.02). These
> are intentionally different values today; converging them is the whole point.

### The tenant→plan link (the one open design choice)

At charge time, `_connect_params` has only the tenant slug. It must resolve that
to a revenue-share rate. Two viable mechanisms:

**Option A (recommended): a direct FK on the tenant row.**
Add `registry.tenants.platform_pricing_plan_id UUID REFERENCES
registry.pricing_plans(id)` (nullable). Set it at signup from the selected plan.
At charge time: `tenant.slug → tenant.platform_pricing_plan_id → plan → rate`.

- Pros: single cheap join at charge time; authoritative per-tenant; the rate
  still lives in the plan (price ops), the tenant just references *which* plan;
  trivially defaultable (NULL → Free plan).
- Cons: adds a column + a sqitch migration.

**Option B: reuse `pricing_relationships` via the primary user.**
At signup, create an `active` `revenue_share` relationship with
`provider_id = platform`, `consumer_id = tenant primary admin user`,
`pricing_plan_id = selected plan`. At charge time:
`slug → tenant → primary user → active platform revenue_share relationship →
plan → rate`.

- Pros: no schema change; uses the table the orphaned seed already populates.
- Cons: multi-join on every charge; couples the tenant's billing rate to a
  specific user row; ambiguous if the primary user changes or multiple
  relationships exist.

**Option A is confirmed** (spec review). It makes the charge-time lookup a
single join, keeps the rate in the plan, and makes the Free-plan fallback a
clean NULL check. The relationship tables are for *selection/discovery* only and
never feed the charge.

**Invariant (pin this in code + a follow-up issue):**
`tenants.platform_pricing_plan_id` is the single charge-time authority for a
tenant's revenue-share rate. Plan-switching is out of scope for #267; whenever
it is built, the switch MUST update this column. Leave a code comment at the
column/resolver stating this, and file a follow-up issue so a future plan-switch
path cannot silently diverge the charged rate from the selected plan.

### The Free default plan

Seed a platform plan: `plan_scope='tenant'`, `pricing_model_type='percentage'`,
`amount = 0.00`, `pricing_configuration = {"percentage": 0.00,
"applies_to": "customer_payments"}`, name e.g. `Registry Free`. This is the
resolution target when `tenants.platform_pricing_plan_id IS NULL`. Because its
rate is 0.00, the derived `application_fee_amount` is 0 and the destination
charge still settles fully into the tenant's connected account.

## Architecture / implementation

### 1. Rate resolution in price ops

Add a single resolver — the only code that knows how to turn a tenant into a
revenue-share fraction. Natural home: `Registry::PriceOps::UnifiedPricingEngine`
(it already owns `revenue_share` relationship typing and amount calculation), or
a small `Registry::PriceOps::RevenueShare` if the engine's constructor is
awkward to use from the payment path.

```
# returns the revenue-share fraction (e.g. 0.02) for a tenant, resolving to the
# seeded Free plan (0.00) when the tenant has no linked platform plan.
method revenue_share_fraction_for_tenant ($db, $tenant_slug) { ... }
```

Resolution order:
1. `tenant.platform_pricing_plan_id` → plan → `pricing_configuration.percentage`
   (fall back to `amount` if the config key is absent).
2. If NULL → the seeded Free plan → `0.00`.
3. If the Free plan is somehow missing (should be impossible post-#268) → die
   with a clear message rather than silently charging a guessed rate. Failing
   loud here is correct: a missing Free plan is a deploy bug, not a runtime
   condition to paper over.

**Schema qualification (charge-time correctness):** the resolver is called from
`_connect_params`, which runs with `search_path` set to the *tenant* schema
(tenant-scoped payments, per commit `2e2b55a`). All tables in the resolver query
MUST be fully qualified (`registry.tenants`, `registry.pricing_plans`), matching
the existing `registry.tenants` lookup three lines away in `_connect_params`. Do
**not** mutate `search_path` mid-charge. A test must exercise the resolver while
the connection's `search_path` is a tenant schema, not just the default
`registry`, so this cannot regress.

### 2. Payment path

In `Registry::DAO::Payment`:
- Delete `use constant REVENUE_SHARE_PERCENT => 2.5`.
- Replace `application_fee_cents($amount_cents)` (currently constant-based) with
  a version that takes the resolved fraction:
  `application_fee_cents($amount_cents, $fraction)` returning
  `int($amount_cents * $fraction + 0.5)` (round half up, integer cents).
- `_connect_params($db, $metadata, $amount)` calls the resolver with the tenant
  slug it already extracts, then passes the fraction to `application_fee_cents`.
  The destination/`on_behalf_of` logic is unchanged.

### 3. Signup display

In `Registry::DAO::WorkflowSteps::TenantPayment`:
- Remove the re-exported `REVENUE_SHARE_PERCENT` constant and the hardcoded
  `revenue_share_percent => 2.5` / `'2.5% of processed revenue.'` in the Solo
  fallback of `get_subscription_config`.
- Derive the displayed rate from the same plan the tenant selected (or the Free
  default), so display and charge read one value.

### 4. Persist the link at signup

The provisioning path is `TenantPayment::_provision_tenant($db, $run)` →
`Registry::DAO::Tenant->provision($class, $db, $data)`. (`create_tenant_directly`
was removed in commit `3143217`; do not reference it.) `provision` filters its
input through a `%TENANT_COLUMNS` whitelist before INSERT — the same mechanism
the Connect fields use.

- Add `platform_pricing_plan_id` to the `%TENANT_COLUMNS` whitelist in
  `Tenant->provision` (alongside `stripe_connect_account_id` et al.).
- `PricingPlanSelection` already stashes `selected_pricing_plan` in workflow run
  data. Have `_provision_tenant` pass `selected_pricing_plan`'s plan id into the
  data hash it builds for `provision`.
- If no plan was selected, the key is absent → column NULL → resolves to Free.

### 4b. Backfill existing tenants (money-path safety)

When this column is added, every already-provisioned tenant (including live prod
tenants) would otherwise be NULL → 0%, silently dropping from the current charge
to free. The migration that adds `platform_pricing_plan_id` MUST also backfill
every existing tenant to the launch revenue-share plan's id in the same change.
NULL is then reserved for genuinely-planless tenants only. (Spec-review
decision: backfill migration, option A.)

### 5. #268 prerequisite — make plans real on deploy (PR1)

- Add `create-default-pricing-relationships` to `sql/sqitch.plan` with correct
  `requires:` ordering, and run a scratch-DB deploy/revert/verify cycle.
- Ensure the Free plan is seeded (either in the existing
  `unified-pricing-infrastructure` seed or the relationship seed).
- Add the orphan-check to CI (one line, fails the build on any unplanned
  `sql/deploy/*.sql`):
  ```bash
  for f in sql/deploy/*.sql; do n=$(basename "$f" .sql); \
    grep -q "^$n " sql/sqitch.plan || echo "ORPHAN: $n"; done
  ```

### 6. Launch-rate flag

Leave the seeded revenue-share plan at its current `0.02` and add a comment at
that single seed location marking it as the launch-rate decision point
(2%-vs-2.5%, deferred). Changing the launch rate is then a one-line data edit.

## Error handling

- **Missing Free plan:** die with an explicit message (deploy bug). Do not
  default to a numeric constant — that would reintroduce exactly what this issue
  removes.
- **Tenant has no `stripe_connect_account_id`:** unchanged from current
  `_connect_params` behavior (returns no Connect params; the readiness gate
  already guarantees a connected account before paid enrollment).
- **Malformed plan config** (non-numeric / missing percentage and amount):
  treat as a data error and die; covered by a unit test.
- **Rounding:** integer cents, round half up, matching the existing
  `application_fee_cents` contract so no fractional-cent drift is introduced.

## Testing plan

Following strict TDD; each item is a failing test first.

### Unit (`t/dao/`, `t/priceops/`)
1. `revenue_share_fraction_for_tenant` returns the linked plan's fraction
   (0.02) for a tenant with a linked revenue-share plan.
2. Returns `0.00` for a tenant with `platform_pricing_plan_id IS NULL` (Free
   fallback), and the seeded Free plan is what it resolves to.
3. Dies with a clear message when the Free plan is absent.
4. Dies on malformed plan config.
5. `application_fee_cents($cents, $fraction)` round-half-up table:
   e.g. (10000, 0.02) → 200; (10000, 0.025) → 250; (333, 0.02) → 7;
   (0, anything) → 0; (anything, 0.00) → 0.
6. Extend `t/dao/payment-intent-destination-charge.t` (arrives with #271): the
   `application_fee_amount` in the derived Connect params equals
   `round(amount_cents * linked-plan fraction)`, **not** a constant. Add a case
   for a Free-plan tenant asserting `application_fee_amount == 0` with the
   destination still set.
7. Assert `Registry::DAO::Payment` no longer defines `REVENUE_SHARE_PERCENT`
   (e.g. `ok !Registry::DAO::Payment->can('REVENUE_SHARE_PERCENT')`), so the
   constant cannot quietly come back. Also assert
   `Registry::DAO::WorkflowSteps::TenantPayment` no longer re-exports it.
8. **Resolver under a tenant `search_path`:** set the connection's search_path to
   a tenant schema, then call the resolver — it must still return the correct
   rate (proves the `registry.`-qualification). This is the regression guard for
   issue [2].

### Integration (`t/dao/`, workflow)
9. Tenant signup selecting the revenue-share plan persists
   `platform_pricing_plan_id`; a subsequent enrollment charge derives the fee
   from that plan.
10. Signup with no plan selected leaves the link NULL and charges 0% (Free).

### Migration
11. Scratch-DB deploy → verify → revert cycle for the newly-planned
    `create-default-pricing-relationships` change (PR1) and the
    `platform_pricing_plan_id` column migration (PR2). After deploy, the seeded
    Free + launch plans exist and the column is present.
12. CI orphan-check reports no orphaned `sql/deploy/*.sql` (PR1).
13. **Backfill:** after the PR2 migration, assert no pre-existing tenant has a
    NULL `platform_pricing_plan_id` (they were backfilled to the launch plan);
    only tenants created without a plan selection may be NULL.

### Journey (the acceptance gate)
14. `t/user-journeys/alex/03-platform-billing.t` (from #271): remove the
    `TODO` wrapper on the rate-consistency subtest. It must pass green —
    displayed rate == charged rate, both derived from the plan. This is the
    definition of done for #267.

### Full suite
15. `carton exec ./registry workflow import registry` then
    `carton exec prove -lr t/` — 100% pass, pristine output.

## Definition of done

- `REVENUE_SHARE_PERCENT` deleted; no replacement constant anywhere
  (grep-verified).
- Displayed and charged rates both derive from the tenant's plan (or Free).
- Leg 3 rate-consistency assertion passes without `TODO`.
- Platform plans are selectable on a fresh deploy; orphan-check in CI.
- Full suite green, output pristine.

## Spec-review outcomes (2026-06-13)

Resolved:
- **Option A** (FK on tenants) confirmed; relationship tables are
  selection-only.
- **Existing tenants:** backfill migration (no separate tripwire test beyond the
  backfill assertion, test #13).
- **Charge-time lookup:** fully-qualify `registry.` tables; no `search_path`
  mutation; regression test #8.
- **Delivery:** two stacked PRs (PR1 = #268, PR2 = #267).
- **Plan switching:** out of scope; invariant pinned + follow-up issue to file.

Deferred to implementation/planning (low-risk, no blocker):
1. Resolver home — `UnifiedPricingEngine` vs a dedicated
   `Registry::PriceOps::RevenueShare`. Lean dedicated module if the engine's
   constructor is awkward to call from the payment path; decide when writing the
   plan.
2. Free-plan seed location — fold into PR1's seed work; pick
   `unified-pricing-infrastructure` vs the relationship migration based on
   sqitch `requires:` ordering at implementation time.
3. The launch rate number (2% vs 2.5%) — deferred per decision; flagged at the
   single seed location.
