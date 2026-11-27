-- ABOUTME: Drops the waitlist queue from registry and every tenant schema,
-- ABOUTME: including tenants clone_schema provisioned since deploy.

-- Revert registry:waitlist-entries from pg

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
        EXECUTE format('DROP TABLE IF EXISTS %I.waitlist_entries', s);
    END LOOP;
END $$;

COMMIT;
