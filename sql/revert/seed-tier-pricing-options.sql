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

-- By the stamp the deploy wrote, not by shape. Deleting every unreferenced
-- coming-soon tenant plan would take an operator's own row with it -- and it
-- would, because deploy.verify is on: a collision makes verify fail, sqitch
-- reverts the change it just deployed, and this statement runs.
DELETE FROM registry.pricing_plans
 WHERE metadata->>'created_by_migration' = 'seed-tier-pricing-options';

UPDATE registry.pricing_plans
   SET plan_name = 'Registry Revenue Share',
       -- Both descriptions go back to what the parent had: the one this change
       -- wrote into pricing_configuration is removed, and the one it deleted
       -- from metadata is restored. Restating that string is the cost of the
       -- deploy having deleted it; a revert that drops a key its parent carried
       -- lands a state that never existed, which is the whole point of the
       -- assertion in t/database/seed-tier-pricing-options.t.
       --
       -- One assignment: Postgres refuses two SETs of the same column, and
       -- splitting them into two statements would make the revert's order
       -- load-bearing for no reason.
       metadata = ( ( metadata - 'display_order' ) - 'featured' )
                || jsonb_build_object('description',
                       'Revenue share on customer payments, no minimums'),
       pricing_configuration = pricing_configuration - 'description',
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'launch_rate' = 'true';

-- And the name snapshot, mirroring the deploy. Without this the revert leaves
-- the snapshot reading 'Solo' against a plan called 'Registry Revenue Share' --
-- the same staleness the deploy exists to prevent, in the other direction.
UPDATE registry.pricing_relationships pr
   SET metadata   = pr.metadata || jsonb_build_object('plan_name', p.plan_name),
       updated_at = CURRENT_TIMESTAMP
  FROM registry.pricing_plans p
 WHERE p.id = pr.pricing_plan_id
   AND p.metadata->>'launch_rate' = 'true'
   AND pr.metadata->>'plan_name' IS DISTINCT FROM p.plan_name;

COMMIT;
