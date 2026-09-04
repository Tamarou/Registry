-- ABOUTME: Remove the Studio and Empire anchor tiers and restore the plan's internal name.
-- ABOUTME: Deletes the relationship before the plan, since the relationship references it.

-- Revert registry:seed-tier-pricing-options from pg

BEGIN;

SET client_min_messages = 'warning';

-- By the migration that created them, not by name: a plan someone renamed by
-- hand is still this change's to remove, and a plan named Studio that this
-- change did not create is not.
DELETE FROM registry.pricing_relationships
 WHERE metadata->>'created_by_migration' = 'seed-tier-pricing-options';

DELETE FROM registry.pricing_plans p
 WHERE p.plan_scope = 'tenant'
   AND p.metadata->>'coming_soon' = 'true'
   AND NOT EXISTS (
       SELECT 1 FROM registry.pricing_relationships pr
        WHERE pr.pricing_plan_id = p.id
   );

UPDATE registry.pricing_plans
   SET plan_name = 'Registry Revenue Share',
       metadata  = ( metadata - 'display_order' ) - 'featured',
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'launch_rate' = 'true';

COMMIT;
