-- ABOUTME: Drop entitlement units and holds from registry and every tenant schema.
-- ABOUTME: Nothing has been sold through them yet, so no data is carried anywhere.

-- Revert registry:priceops-entitlement-units from pg

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
        EXECUTE format('DROP TABLE IF EXISTS %I.holds', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.entitlement_units', s);
    END LOOP;
END $$;

COMMIT;
