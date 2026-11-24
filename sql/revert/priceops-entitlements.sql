-- ABOUTME: Drop entitlements from registry and every tenant schema.
-- ABOUTME: Nothing has been sold through them yet, so no data is carried anywhere.

-- Revert registry:priceops-entitlements from pg

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
        EXECUTE format('DROP TABLE IF EXISTS %I.entitlements', s);
    END LOOP;
END $$;

-- clone_schema copies registry's functions too, so a tenant provisioned after
-- deploy has its own copy; tables first, so no trigger still uses one.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug::name FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %I.entitlement_stamp()', s);
    END LOOP;
END $$;
DROP FUNCTION IF EXISTS registry.entitlement_stamp();

COMMIT;
