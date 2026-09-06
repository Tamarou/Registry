-- ABOUTME: Move the offered revenue-share plan to the launch rate and mark it as the launch plan.
-- ABOUTME: Three rates were live at once: 0% resolved, 2% charged, 2.5% advertised.

-- Deploy registry:set-launch-revenue-share-rate to pg
-- requires: retire-registry-plus-plan

BEGIN;

SET client_min_messages = 'warning';

-- Three rates were live simultaneously. A tenant linked to the seeded plan was
-- charged 2%; a tenant with no linked plan resolved the platform Free plan and
-- was charged 0%; and both signup pages advertise 2.5%. The decision (recorded
-- in the PriceOps alignment spec) is that the code moves to meet the copy.
--
-- Tenants link to the plan by FK, so updating the plan's rate moves every
-- linked tenant with it -- there is no per-tenant row to repair. That is the
-- reason the FK exists.
--
-- Selected by shape, not by name: the plan currently on offer to tenants that
-- carries a rate. Matching on 'Registry Revenue Share - 2%' would be matching on
-- the very string this change has to remove.
UPDATE registry.pricing_plans p
   SET pricing_configuration = p.pricing_configuration
                             || '{"percentage": 0.025}'::jsonb,
       -- The name is rendered on the signup pricing page. Leaving "- 2%" on a
       -- plan that charges 2.5% would put the old rate in front of the customer
       -- at the moment they agree to the new one. The rate lives in
       -- pricing_configuration, which is the only place anything reads it.
       plan_name = 'Registry Revenue Share',
       -- Marked, not inferred. platform_launch_fraction needs to find this row
       -- without guessing, and "newest tenant-scope percentage plan" is a
       -- coincidence that stops being true the moment a second one is seeded.
       --
       -- The description goes with it. Nothing reads it, which is precisely why
       -- it would have kept saying "2%" indefinitely -- a stale rate no code
       -- consults and every operator debugging a pricing question does.
       metadata = p.metadata
                || '{"launch_rate": true}'::jsonb
                || jsonb_build_object('description',
                       'Revenue share on customer payments, no minimums'),
       updated_at = CURRENT_TIMESTAMP
  FROM registry.pricing_relationships pr
 WHERE pr.pricing_plan_id = p.id
   AND pr.status = 'active'
   AND pr.provider_id = '00000000-0000-0000-0000-000000000000'::UUID
   AND p.plan_scope = 'tenant'
   AND p.pricing_configuration ? 'percentage';

-- The relationship carries a snapshot of the plan name taken when it was
-- created. Also unread, also stale the moment the plan is renamed. Refreshed
-- from the plan rather than hardcoded, so this cannot itself go stale.
UPDATE registry.pricing_relationships pr
   SET metadata   = pr.metadata
                  || jsonb_build_object('plan_name', p.plan_name),
       updated_at = CURRENT_TIMESTAMP
  FROM registry.pricing_plans p
 WHERE p.id = pr.pricing_plan_id
   AND p.metadata->>'launch_rate' = 'true'
   AND pr.metadata->>'plan_name' IS DISTINCT FROM p.plan_name;

-- Exactly one plan must carry the mark, or platform_launch_fraction has to pick,
-- and a resolver that picks is the thing this change exists to remove. Fail the
-- deploy rather than leave the platform advertising a rate it cannot resolve.
DO $$
DECLARE
    marked integer;
BEGIN
    SELECT COUNT(*) INTO marked
      FROM registry.pricing_plans
     WHERE metadata->>'launch_rate' = 'true';

    IF marked <> 1 THEN
        RAISE EXCEPTION
            'expected exactly one plan marked launch_rate, found %. '
            'The offered tenant-scope percentage plan is what this change '
            'marks; check registry.pricing_relationships for what is active.',
            marked;
    END IF;
END $$;

COMMIT;
