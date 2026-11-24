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

COMMIT;
