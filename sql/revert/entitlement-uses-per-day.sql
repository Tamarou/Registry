-- ABOUTME: Back to one use per (entitlement, occurrence): absent marks and session-day marks go, present occurrence uses stay.
-- ABOUTME: In registry and every tenant schema; the make-up credit links go with their absences.

-- Revert registry:entitlement-uses-per-day from pg

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
        CONTINUE WHEN to_regclass(format('%I.entitlement_uses', s)) IS NULL;
        -- Before this change a row meant present at an occurrence: absences
        -- go, and so do a session's days, which that key cannot tell apart
        -- and whose backfill on redeploy would have no day to find.
        EXECUTE format($f$
            DELETE FROM %1$I.entitlement_uses u
             WHERE u.mark = 'absent'
                OR NOT EXISTS (SELECT 1 FROM %1$I.resources r WHERE r.id = u.occurrence_id AND r.event_id = u.event_id)
        $f$, s);
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlement_uses
                DROP CONSTRAINT entitlement_uses_pkey,
                ADD CONSTRAINT entitlement_uses_pkey PRIMARY KEY (entitlement_id, occurrence_id),
                DROP COLUMN credit_entitlement_id,
                DROP COLUMN mark,
                DROP COLUMN event_id
        $f$, s);
    END LOOP;
END $$;

COMMIT;
