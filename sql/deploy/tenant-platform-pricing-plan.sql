-- ABOUTME: Add tenants.platform_pricing_plan_id FK and backfill existing tenants.
-- ABOUTME: The tenant's platform plan is the single charge-time authority for the revenue-share rate (#267).

-- Deploy registry:tenant-platform-pricing-plan to pg
-- requires: create-default-pricing-relationships

BEGIN;

ALTER TABLE registry.tenants
    ADD COLUMN IF NOT EXISTS platform_pricing_plan_id UUID
    REFERENCES registry.pricing_plans(id);

-- Backfill every existing tenant to the launch revenue-share plan so no tenant
-- silently drops to a 0% fee. LAUNCH-RATE DECISION POINT: this selector picks
-- the seeded "Registry Revenue Share" percentage plan (currently 2%); the
-- 2%-vs-2.5% number is deferred and changing it is a one-line data edit.
UPDATE registry.tenants
   SET platform_pricing_plan_id = (
        SELECT id FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND pricing_model_type = 'percentage'
           AND metadata->>'default' IS DISTINCT FROM 'true'
         ORDER BY created_at
         LIMIT 1
   )
 WHERE platform_pricing_plan_id IS NULL;

COMMIT;
