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

    IF rate IS DISTINCT FROM 0.025 THEN
        RAISE EXCEPTION 'launch plan carries rate %, expected 0.025', rate;
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
