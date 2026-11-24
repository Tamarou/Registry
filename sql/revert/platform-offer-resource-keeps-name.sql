-- ABOUTME: Drop the guard on the platform offer's resource name, in registry and every tenant copy.
-- ABOUTME: clone_schema gave tenants provisioned since its own no-op copy of the function and trigger.

-- Revert registry:platform-offer-resource-keeps-name from pg

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
        IF to_regclass(format('%I.resources', s)) IS NOT NULL THEN
            EXECUTE format('DROP TRIGGER IF EXISTS resources_keep_platform_offer_name ON %I.resources', s);
        END IF;
        EXECUTE format('DROP FUNCTION IF EXISTS %I.resources_keep_platform_offer_name()', s);
    END LOOP;
END $$;

COMMIT;
