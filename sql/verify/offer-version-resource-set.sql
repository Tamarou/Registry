-- ABOUTME: Verify every schema with offer versions has the resource set table and its guards.
-- ABOUTME: Without them a set version could change after publish or be published buying nothing.

-- Verify registry:offer-version-resource-set on pg

BEGIN;

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
        IF to_regclass(format('%I.offer_version_resources', s)) IS NULL
           OR NOT EXISTS (SELECT 1 FROM pg_trigger
                           WHERE tgrelid = to_regclass(format('%I.offer_version_resources', s))
                             AND tgname = 'offer_version_resources_guard')
           OR NOT EXISTS (SELECT 1 FROM pg_trigger
                           WHERE tgrelid = to_regclass(format('%I.offer_version_resources', s))
                             AND tgname = 'offer_version_resources_no_truncate')
           OR NOT EXISTS (SELECT 1 FROM pg_trigger
                           WHERE tgrelid = to_regclass(format('%I.offer_versions', s))
                             AND tgname = 'offer_versions_require_purchase')
        THEN
            RAISE EXCEPTION 'schema % lacks the offer version resource set or its guards', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
