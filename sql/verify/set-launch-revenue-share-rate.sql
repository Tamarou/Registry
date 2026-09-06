-- ABOUTME: Verify exactly one plan is marked as the launch plan and carries the launch rate.
-- ABOUTME: Asserts the mark, the rate, and that the plan name no longer states a rate.

-- Verify registry:set-launch-revenue-share-rate on pg

BEGIN;

DO $$
DECLARE
    marked   integer;
    rate     numeric;
    the_name text;
BEGIN
    SELECT COUNT(*) INTO marked
      FROM registry.pricing_plans
     WHERE metadata->>'launch_rate' = 'true';

    IF marked <> 1 THEN
        RAISE EXCEPTION 'expected exactly one launch_rate plan, found %', marked;
    END IF;

    SELECT (pricing_configuration->>'percentage')::numeric, plan_name
      INTO rate, the_name
      FROM registry.pricing_plans
     WHERE metadata->>'launch_rate' = 'true';

    -- A rate, not THE rate. sqitch re-runs every verify against the final
    -- schema (t/database/migration-verification.t), so a verify that pins a
    -- business decision becomes a tripwire on the next change that moves it --
    -- which is a change of exactly this shape. The value of the launch rate is
    -- pinned in t/priceops/tier-options.t, which is versioned with the code
    -- that quotes it. What must hold forever is that the marked plan carries a
    -- usable fraction at all.
    IF rate IS NULL OR rate <= 0 OR rate > 1 THEN
        RAISE EXCEPTION
            'launch plan carries rate %, which is not a usable fraction', rate;
    END IF;

    -- The rate belongs in pricing_configuration and nowhere else. A name that
    -- states a rate is a second source that no code reads and every customer
    -- does, and it is what made "2%" survive a move to 2.5% on the signup page.
    IF the_name ~ '[0-9]+(\.[0-9]+)?\s*%' THEN
        RAISE EXCEPTION
            'launch plan name % states a rate; the rate lives in pricing_configuration',
            the_name;
    END IF;
END $$;

ROLLBACK;
