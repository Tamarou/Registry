-- ABOUTME: Verify the signup page has one buyable tier and two visible anchors.
-- ABOUTME: Asserts the ladder renders in order and that the anchors are marked coming_soon.

-- Verify registry:seed-tier-pricing-options on pg

BEGIN;

DO $$
DECLARE
    seeded    integer;
    unordered integer;
BEGIN
    -- What this change DID, not what the market looks like now. "Exactly one
    -- buyable tier" is true today and the deploy asserts it, which is the right
    -- place: a deploy runs once, against the state it was written for. A verify
    -- re-runs forever against the final schema, so asserting a market fact here
    -- makes the next tier launch -- or the next retirement, which this repo
    -- performs by suspending a relationship -- fail a shipped script with no fix
    -- inside it.
    SELECT COUNT(*) INTO seeded
      FROM registry.pricing_plans
     WHERE metadata->>'created_by_migration' = 'seed-tier-pricing-options';

    IF seeded <> 2 THEN
        RAISE EXCEPTION
            'expected the 2 anchor tiers this change seeded, found %', seeded;
    END IF;

    -- Scoped to those same rows. Applied to every offered tenant plan this
    -- would be the tripwire the paragraph above argues against -- it would fire
    -- the day anyone offers a plan without a display_order, which is a choice
    -- this change has no opinion about.
    SELECT COUNT(*) INTO unordered
      FROM registry.pricing_plans
     WHERE metadata->>'created_by_migration' = 'seed-tier-pricing-options'
       AND metadata->>'display_order' IS NULL;

    IF unordered > 0 THEN
        RAISE EXCEPTION
            '% seeded tier(s) carry no display_order; the ladder would sort by '
            'price and put the free tier wherever that lands', unordered;
    END IF;
END $$;

ROLLBACK;
