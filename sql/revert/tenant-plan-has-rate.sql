-- ABOUTME: Drop the trigger that refuses linking a tenant to a plan with no rate.
-- ABOUTME: Such a link is then caught only when RevenueShare dies at checkout.

-- Revert registry:tenant-plan-has-rate from pg

BEGIN;

DROP TRIGGER IF EXISTS tenants_plan_has_rate ON registry.tenants;
DROP FUNCTION IF EXISTS registry.tenant_plan_has_rate();

COMMIT;
