-- ABOUTME: Verify registry.tenants refuses a link to a pricing plan with no rate.
-- ABOUTME: Without the trigger such a link is found only when a charge dies in RevenueShare.

-- Verify registry:tenant-plan-has-rate on pg

BEGIN;

SELECT 1/count(*) FROM pg_trigger
 WHERE tgrelid = 'registry.tenants'::regclass
   AND tgname = 'tenants_plan_has_rate';

ROLLBACK;
