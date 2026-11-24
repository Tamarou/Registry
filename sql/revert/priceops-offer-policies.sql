-- ABOUTME: Drop offer versions' price, units, payment plans, policies and conditions everywhere.
-- ABOUTME: Nothing has been sold on them yet, so no data is carried anywhere.

-- Revert registry:priceops-offer-policies from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.offer_versions', s)) IS NULL;
        EXECUTE format('DROP TABLE IF EXISTS %I.offer_version_payment_plans', s);
        EXECUTE format('DROP TRIGGER IF EXISTS offer_versions_require_payment_plan ON %I.offer_versions', s);
        EXECUTE format($f$
            ALTER TABLE %I.offer_versions
                DROP COLUMN IF EXISTS price_cents,
                DROP COLUMN IF EXISTS currency,
                DROP COLUMN IF EXISTS units_per_acceptance,
                DROP COLUMN IF EXISTS per_booking_cap,
                DROP COLUMN IF EXISTS policies,
                DROP COLUMN IF EXISTS conditions
        $f$, s);
    END LOOP;
END $$;

-- clone_schema copies registry's functions too, so a tenant provisioned after
-- deploy has its own copy; tables first, so no trigger still uses one.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug::name FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_version_payment_plan_immutable()', s);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_version_requires_payment_plan()', s);
    END LOOP;
END $$;
DROP FUNCTION IF EXISTS registry.offer_version_payment_plan_immutable();
DROP FUNCTION IF EXISTS registry.offer_version_requires_payment_plan();

COMMIT;
