-- ABOUTME: Seed a platform-scope Free (0%) revenue-share plan.
-- ABOUTME: Serves as the no-plan fallback for plan-driven revenue share (#267).

-- Deploy registry:seed-free-platform-plan to pg
-- requires: unified-pricing-infrastructure

BEGIN;

-- NOTE: offering_tenant_id / target_tenant_id were dropped by
-- remove-pricing-plan-relationship-fields (deploys earlier), so they are NOT
-- columns here. Insert only the columns that exist in the current schema
-- (see sql/test-schema.sql pricing_plans definition).
INSERT INTO registry.pricing_plans (
    plan_scope, plan_name, plan_type,
    pricing_model_type, amount, currency, pricing_configuration, metadata
)
SELECT
    'platform',
    'Registry Free',
    'standard',
    'percentage',
    0.00,
    'USD',
    '{"percentage": 0.00, "applies_to": "customer_payments", "minimum_monthly": 0}'::JSONB,
    '{"default": true, "description": "Platform fallback: no revenue share"}'::JSONB
WHERE NOT EXISTS (
    SELECT 1 FROM registry.pricing_plans
    WHERE plan_scope = 'platform' AND metadata->>'default' = 'true'
);

COMMIT;
