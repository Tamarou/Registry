-- ABOUTME: Return the offered revenue-share plan to 2% and drop the launch-plan mark.
-- ABOUTME: Selected by the mark, so it reverses exactly the row the deploy moved.

-- Revert registry:set-launch-revenue-share-rate from pg

BEGIN;

SET client_min_messages = 'warning';

-- By the mark, not by shape. The deploy selected the plan on offer; by the time
-- a revert runs, what is on offer may have changed, and reverting the wrong row
-- would leave the rate wrong in a way nothing detects. The mark names exactly
-- the row that moved.
UPDATE registry.pricing_plans
   SET pricing_configuration = pricing_configuration
                             || '{"percentage": 0.02}'::jsonb,
       plan_name  = 'Registry Revenue Share - 2%',
       metadata   = ( metadata - 'launch_rate' )
                  || jsonb_build_object('description',
                         '2% of all customer payments, no minimums'),
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'launch_rate' = 'true';

-- Put the relationship's name snapshot back with it, by the same rule the
-- deploy used: read it off the plan rather than restating it.
UPDATE registry.pricing_relationships pr
   SET metadata   = pr.metadata
                  || jsonb_build_object('plan_name', p.plan_name),
       updated_at = CURRENT_TIMESTAMP
  FROM registry.pricing_plans p
 WHERE p.id = pr.pricing_plan_id
   AND p.plan_name = 'Registry Revenue Share - 2%'
   AND pr.metadata->>'plan_name' IS DISTINCT FROM p.plan_name;

COMMIT;
