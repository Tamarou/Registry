# Plan-Driven Revenue Share (PR2 / #267) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Derive the platform revenue-share rate from the tenant's pricing plan instead of the hardcoded `REVENUE_SHARE_PERCENT = 2.5` constant, so the rate displayed at signup and the rate charged as the Stripe `application_fee_amount` come from one source and cannot drift.

**Architecture:** Persist a tenant→platform-plan link as a nullable FK `tenants.platform_pricing_plan_id` (set at signup from the selected plan; existing tenants backfilled to the launch plan). A single resolver reads that plan's revenue-share fraction at charge time (NULL → the seeded platform Free plan = 0%). `Registry::DAO::Payment::_connect_params` calls the resolver and passes the fraction to `application_fee_cents`; the `REVENUE_SHARE_PERCENT` constant is deleted from both `Payment` and `TenantPayment`.

**Tech Stack:** PostgreSQL, Sqitch migrations (deploy/revert/verify), Perl 5.42 / Object::Pad, Test2/Test::More, Mojo::Pg, Stripe Connect destination charges.

**Spec:** `docs/specs/plan-driven-revenue-share.md` (PR2 section). This is PR3 of the stack; PR1 (#268, merged) seeded the platform Free plan (`plan_scope='platform'`, `metadata->>'default'='true'`, amount 0.00) and the `create-default-pricing-relationships` migration. Branch: `feature/plan-driven-revenue-share` (off merged main).

## Locked decisions (from spec review)
- **Option A:** nullable FK `tenants.platform_pricing_plan_id` is the single charge-time authority. Relationship tables are selection-only.
- **No-plan fallback:** resolve to the seeded platform Free plan (0%). No numeric constant survives anywhere.
- **Existing tenants:** the column-adding migration backfills every existing tenant to the launch revenue-share plan id (no silent drop to 0%).
- **Charge-time lookup:** fully-qualify `registry.*` tables (runs under a tenant `search_path`); no `search_path` mutation.
- **Launch rate (2% vs 2.5%):** DEFERRED. Build the architecture; the launch plan is the existing seeded "Registry Revenue Share - 2%" plan. Flag the one seed location; do not change the number.
- **Plan switching:** out of scope; `platform_pricing_plan_id` is the authority — file a follow-up so any future switch updates it.

## Current state (verified on merged main)
- `lib/Registry/DAO/Payment.pm:11` `use constant REVENUE_SHARE_PERCENT => 2.5;`
- `application_fee_cents($amount_cents)` = `int($amount_cents * REVENUE_SHARE_PERCENT / 100 + 0.5)`.
- `_connect_params($db, $metadata, $amount)` (a `sub`): coerces `$db = $db->db if $db isa Registry::DAO`, reads `$meta->{tenant_slug}`, returns `()` for `registry`/no-slug, queries `SELECT stripe_connect_account_id FROM registry.tenants WHERE slug = ?`, and on an account returns `transfer_data[destination]`, `on_behalf_of`, `application_fee_amount => application_fee_cents(_to_cents($amount))`.
- `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm` re-exports the constant (`use constant REVENUE_SHARE_PERCENT => Registry::DAO::Payment::REVENUE_SHARE_PERCENT;`) and uses it for signup display copy in `get_subscription_config`.
- `TenantPayment::_provision_tenant($db, $run)` (line 363) builds `$data = $run->data` and calls `Tenant->provision`; the selected plan is at `$run->data->{selected_pricing_plan}` (a hash with `id`, etc.).
- `Tenant->provision` filters via `%TENANT_COLUMNS` (Tenant.pm:139) — currently includes `stripe_connect_account_id stripe_charges_enabled stripe_details_submitted`.
- `registry.tenants` created in `tenant-on-boarding.sql`; the Connect column was added by `tenant-stripe-connect.sql` via `ALTER TABLE tenants ADD COLUMN IF NOT EXISTS ...`.
- Seeded plans (registry schema): platform Free (`plan_scope='platform'`, `metadata->>'default'='true'`, amount 0.00, `pricing_configuration.percentage`=0.00); "Registry Revenue Share - 2%" (`plan_scope='tenant'`, `pricing_model_type='percentage'`, amount 0.02, `pricing_configuration.percentage`=0.02).
- Leg 3 guard: `t/user-journeys/alex/03-platform-billing.t:284` subtest reads `Registry::DAO::Payment::REVENUE_SHARE_PERCENT` under a `TODO` block (line 296).

## File Structure
- Create: `sql/deploy|revert|verify/tenant-platform-pricing-plan.sql` — the FK column + backfill.
- Create: `lib/Registry/PriceOps/RevenueShare.pm` — the rate resolver (focused module; `_connect_params` is a plain sub and a heavy engine constructor would be awkward to call per-charge).
- Create: `t/priceops/revenue-share.t` — resolver unit tests.
- Modify: `lib/Registry/DAO/Payment.pm` — delete constant; `application_fee_cents($cents, $fraction)`; `_connect_params` resolves the fraction.
- Modify: `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm` — delete the re-exported constant; derive display rate from the plan; persist the link in `_provision_tenant`.
- Modify: `lib/Registry/DAO/Tenant.pm` — add `platform_pricing_plan_id` to `%TENANT_COLUMNS` (+ a `field`/reader if the class needs it).
- Modify: `sql/sqitch.plan` (+ regenerate `sql/test-schema.sql`).
- Modify: `t/dao/payment-intent-destination-charge.t` — assert fee derives from the plan, add a Free-plan (0%) case.
- Modify: `t/user-journeys/alex/03-platform-billing.t` — drop the TODO; assert displayed == charged, both plan-derived.

---

## Task 1: Migration — `tenants.platform_pricing_plan_id` FK + backfill

**Files:** `sql/deploy|revert|verify/tenant-platform-pricing-plan.sql`

- [ ] **Step 1: deploy** — `ALTER TABLE registry.tenants ADD COLUMN IF NOT EXISTS platform_pricing_plan_id UUID REFERENCES registry.pricing_plans(id);` then backfill: `UPDATE registry.tenants SET platform_pricing_plan_id = (SELECT id FROM registry.pricing_plans WHERE plan_scope='tenant' AND pricing_model_type='percentage' AND metadata->>'default' IS DISTINCT FROM 'true' ORDER BY created_at LIMIT 1) WHERE platform_pricing_plan_id IS NULL;` (the launch "Registry Revenue Share - 2%" plan). Add an ABOUTME + a comment marking the launch-plan selector as the rate decision point. `requires: seed-free-platform-plan` (needs the plans present).
- [ ] **Step 2: revert** — `ALTER TABLE registry.tenants DROP COLUMN IF EXISTS platform_pricing_plan_id;`
- [ ] **Step 3: verify** — `SELECT 1/COUNT(*)` style: assert the column exists (`information_schema.columns`). BEGIN/ROLLBACK.
- [ ] **Step 4:** add to `sql/sqitch.plan` (after `create-default-pricing-relationships`), `make test-schema`, scratch deploy/verify/revert/redeploy cycle.
- [ ] **Step 5:** commit.

> NOTE: backfill targets the launch plan; the SELECT is the single rate-decision point (2% vs 2.5% deferred). Confirm exactly one tenant-scoped percentage non-default plan exists, or tighten the selector by plan_name.

## Task 2: Rate resolver `Registry::PriceOps::RevenueShare`

**Files:** Create `lib/Registry/PriceOps/RevenueShare.pm`; test `t/priceops/revenue-share.t`.

- [ ] **Step 1 (TDD):** write `t/priceops/revenue-share.t` first — fraction for a tenant linked to the 2% plan returns 0.02; tenant with NULL link returns 0.00 (Free); resolver runs correctly under a tenant `search_path`; dies clearly if the Free plan is absent; malformed config dies.
- [ ] **Step 2:** run, confirm red.
- [ ] **Step 3:** implement `revenue_share_fraction_for_tenant($db, $tenant_slug)`: fully-qualified query joining `registry.tenants` → `registry.pricing_plans` on `platform_pricing_plan_id`; read `pricing_configuration->>'percentage'` (fallback to `amount`); on NULL link, read the platform Free plan (`plan_scope='platform'` AND `metadata->>'default'='true'`); die if Free plan missing. Coerce `$db = $db->db if $db isa Registry::DAO`.
- [ ] **Step 4:** green. **Step 5:** commit.

## Task 3: Payment.pm — derive the fee from the fraction

**Files:** `lib/Registry/DAO/Payment.pm`; `t/dao/payment-intent-destination-charge.t`.

- [ ] **Step 1 (TDD):** extend the destination-charge test: a tenant linked to the 2% plan yields `application_fee_amount == round(amount_cents * 0.02)`; a Free-plan / NULL-link tenant yields `application_fee_amount == 0` with destination still set; assert `!Registry::DAO::Payment->can('REVENUE_SHARE_PERCENT')`.
- [ ] **Step 2:** red. **Step 3:** implement — delete `use constant REVENUE_SHARE_PERCENT`; `application_fee_cents($amount_cents, $fraction)` → `int($amount_cents * $fraction + 0.5)`; `_connect_params` calls `Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant($db, $slug)` and passes it. Keep destination/on_behalf_of unchanged.
- [ ] **Step 4:** green. **Step 5:** commit.

## Task 4: TenantPayment.pm — persist link + plan-derived display

**Files:** `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm`; `lib/Registry/DAO/Tenant.pm`.

- [ ] **Step 1:** add `platform_pricing_plan_id` to `%TENANT_COLUMNS` in `Tenant->provision` (and a `field $platform_pricing_plan_id :param :reader = undef;` if the class reads it).
- [ ] **Step 2:** in `_provision_tenant`, pass `platform_pricing_plan_id => $run->data->{selected_pricing_plan}{id}` into the provision data when a plan was selected (absent → NULL → Free).
- [ ] **Step 3:** remove the re-exported `REVENUE_SHARE_PERCENT` and the hardcoded display rate in `get_subscription_config`; derive the displayed rate from the selected/Free plan (single source). **CRITICAL:** derive the displayed revenue-share rate from `pricing_configuration->{percentage}` (× 100), NOT from the plan's `amount`. The stashed `selected_pricing_plan` sets `amount => int($selected_plan->amount)` (`PricingPlanSelection.pm:67`), so for the 2% plan `amount` is `int(0.02) == 0` — lossy. The `pricing_configuration` (percentage 0.02) is stashed intact. The existing `get_subscription_config` selected-plan branch uses `monthly_amount => $selected_plan->{amount}`; do NOT reuse that path for the revenue-share rate or display will render 0% and the Leg 3 displayed==charged assertion will fail. Add/adjust a unit test asserting persistence + that the displayed rate matches the plan's `pricing_configuration.percentage`.
- [ ] **Step 4:** green. **Step 5:** commit.

## Task 5: Leg 3 — take the TODO off

**Files:** `t/user-journeys/alex/03-platform-billing.t`.

- [ ] **Step 1:** rewrite the `rate-consistency` subtest: remove the `TODO` block and the `REVENUE_SHARE_PERCENT` read; assert the displayed plan rate equals the rate charged for that tenant (both derived from the plan) — i.e. `displayed_rate == revenue_share_fraction_for_tenant * 100`. This is the definition of done for #267.
- [ ] **Step 2:** run the leg, green (no TODO).
- [ ] **Step 3:** commit.

## Task 6: Full-suite verification + blast radius

- [ ] **Step 1:** `make test-schema` (current), `carton exec ./registry workflow import registry`, `carton exec prove -lr t/`. 100% pass.
- [ ] **Step 2:** fix any tests that assumed the constant or a constant fee (same discipline as PR1). Likely candidates: any test referencing `REVENUE_SHARE_PERCENT`, signup display tests asserting "2.5%".
- [ ] **Step 3:** grep-verify no `REVENUE_SHARE_PERCENT` remains anywhere in `lib/` or `t/`.

## Definition of done
- `REVENUE_SHARE_PERCENT` deleted; no replacement constant (grep-clean).
- Displayed and charged rates both derive from the tenant's plan (or Free).
- `tenants.platform_pricing_plan_id` set at signup; existing tenants backfilled.
- Leg 3 rate-consistency passes without `TODO`.
- Full suite green and pristine.
- Follow-up issue filed: plan-switching must update `platform_pricing_plan_id`.

## Open items to confirm before/with execution
1. Resolver home: dedicated `Registry::PriceOps::RevenueShare` (assumed) vs folding into `UnifiedPricingEngine`.
2. Backfill selector: confirm it uniquely identifies the launch "Registry Revenue Share - 2%" plan (by scope+model+non-default, or by plan_name).
3. Launch rate number stays 0.02 (deferred); flagged at the backfill selector + the seed.
