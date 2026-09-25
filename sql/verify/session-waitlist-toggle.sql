-- ABOUTME: Verify every schema holding sessions carries the waitlist toggle.
-- ABOUTME: Checked across tenants, because registry alone is not where programmes live.

-- Verify registry:session-waitlist-toggle on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.sessions', s)) IS NULL;

        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = s AND table_name = 'sessions'
               AND column_name = 'waitlist_enabled'
        ) THEN
            RAISE EXCEPTION 'sessions.waitlist_enabled missing in schema %', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
