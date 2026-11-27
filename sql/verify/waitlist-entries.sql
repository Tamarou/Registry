-- ABOUTME: Verify every schema with resources has the waitlist queue
-- ABOUTME: and its one-live-entry-per-child index.

-- Verify registry:waitlist-entries on pg

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
        CONTINUE WHEN to_regclass(format('%I.resources', s)) IS NULL;
        EXECUTE format('SELECT id, resource_id, family_member_id, payer_user_id, joined_at, state, hold_id, '
                       'workflow_run_id, offered_at FROM %I.waitlist_entries WHERE false', s);
        IF to_regclass(format('%I.waitlist_entries_resource_id_family_member_id_idx', s)) IS NULL THEN
            RAISE EXCEPTION 'schema % lacks the one-live-entry-per-child index', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
