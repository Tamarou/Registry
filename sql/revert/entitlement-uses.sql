-- ABOUTME: Drop the entitlement use records from registry and every tenant schema.
-- ABOUTME: Uses are optional attendance marks; nothing else reads them, so nothing is carried anywhere.

-- Revert registry:entitlement-uses from pg

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
        EXECUTE format('DROP TABLE IF EXISTS %I.entitlement_uses', s);
    END LOOP;
END $$;

COMMIT;
