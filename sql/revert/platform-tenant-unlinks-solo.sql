-- ABOUTME: Re-link the platform tenant to Solo, found the way tenant-platform-pricing-plan found it.
-- ABOUTME: A link to some other plan before the deploy is not restored; it is Solo the platform had.

-- Revert registry:platform-tenant-unlinks-solo from pg

BEGIN;

SET client_min_messages = 'warning';

-- Plan ids are generated at deploy, so Solo is found by the original
-- backfill's own predicate rather than by a fixed id.
UPDATE registry.tenants
   SET platform_pricing_plan_id = (
        SELECT id FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND pricing_model_type = 'percentage'
           AND metadata->>'default' IS DISTINCT FROM 'true'
         ORDER BY created_at
         LIMIT 1
   )
 WHERE id = '00000000-0000-0000-0000-000000000000';

COMMIT;
