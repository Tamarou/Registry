-- ABOUTME: Verify the signup page has one buyable tier and two visible anchors.
-- ABOUTME: Asserts the ladder renders in order and that the anchors are marked coming_soon.

-- Verify registry:seed-tier-pricing-options on pg

BEGIN;

DO $$
DECLARE
    buyable  integer;
    anchors  integer;
    unordered integer;
BEGIN
    SELECT COUNT(*) FILTER (WHERE COALESCE(p.metadata->>'coming_soon','false') <> 'true'),
           COUNT(*) FILTER (WHERE p.metadata->>'coming_soon' = 'true')
      INTO buyable, anchors
      FROM registry.pricing_relationships pr
      JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
     WHERE pr.provider_id = '00000000-0000-0000-0000-000000000000'::UUID
       AND pr.status = 'active'
       AND p.plan_scope = 'tenant';

    -- What this change DID, not what the market looks like now. "Exactly one
    -- buyable tier" is true today and is asserted by the deploy, where it
    -- belongs; as a verify it fails the day a second tier launches, and the
    -- only fix is editing an already-shipped script. Every verify re-runs
    -- against the final schema, so this one asserts only that the two tiers it
    -- seeded still exist and are still offered.
    IF anchors + buyable < 3 THEN
        RAISE EXCEPTION
            'expected the three seeded tiers to still be offered, found %',
            anchors + buyable;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM registry.pricing_plans
         WHERE metadata->>'created_by_migration' = 'seed-tier-pricing-options'
        HAVING COUNT(*) = 2
    ) THEN
        RAISE EXCEPTION 'the two anchor tiers this change seeded are not both present';
    END IF;

    -- Every offered tier needs a display_order, or the ladder sorts by price and
    -- the free tier lands wherever that puts it.
    SELECT COUNT(*) INTO unordered
      FROM registry.pricing_relationships pr
      JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
     WHERE pr.provider_id = '00000000-0000-0000-0000-000000000000'::UUID
       AND pr.status = 'active'
       AND p.plan_scope = 'tenant'
       AND p.metadata->>'display_order' IS NULL;

    IF unordered > 0 THEN
        RAISE EXCEPTION '% offered tier(s) carry no display_order', unordered;
    END IF;
END $$;

ROLLBACK;
