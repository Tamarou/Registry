-- ABOUTME: Drop the guard keeping a current platform offer to tenants, in registry and every tenant copy.
-- ABOUTME: clone_schema gave tenants provisioned since its own no-op copy of the function and trigger.

-- Revert registry:platform-offer-to-tenants-guard from pg

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
        IF to_regclass(format('%I.offer_versions', s)) IS NOT NULL THEN
            EXECUTE format('DROP TRIGGER IF EXISTS offer_versions_keep_platform_offer ON %I.offer_versions', s);
        END IF;
        EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_versions_keep_platform_offer()', s);
    END LOOP;
END $$;

COMMIT;
