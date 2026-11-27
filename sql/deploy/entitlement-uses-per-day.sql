-- ABOUTME: A use is a present or absent mark of one day, an occurrence's event or a session's day, keyed per day.
-- ABOUTME: An absence may link the make-up credit it earned; built in registry and every tenant schema.

-- Deploy registry:entitlement-uses-per-day to pg
-- requires: entitlement-past-due-and-transfer

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s       name;
    dayless text;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.entitlement_uses', s)) IS NULL;

        -- occurrence_id stays: the resource whose unit the entitlement holds.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlement_uses
                ADD COLUMN event_id uuid REFERENCES %1$I.events (id),
                ADD COLUMN mark text NOT NULL DEFAULT 'present'
                    CONSTRAINT entitlement_uses_mark CHECK (mark IN ('present', 'absent')),
                ADD COLUMN credit_entitlement_id uuid REFERENCES %1$I.entitlements (id)
        $f$, s);
        -- Every use so far is of an occurrence, so its resource names its event.
        EXECUTE format($f$
            UPDATE %1$I.entitlement_uses u SET event_id = r.event_id
              FROM %1$I.resources r WHERE r.id = u.occurrence_id
        $f$, s);
        -- A use of a session resource, which the old record_use allowed,
        -- names no single day: refuse by name rather than guess one.
        EXECUTE format('SELECT string_agg(DISTINCT entitlement_id::text, '', '') FROM %I.entitlement_uses'
                       ' WHERE event_id IS NULL', s) INTO dayless;
        IF dayless IS NOT NULL THEN
            RAISE EXCEPTION 'entitlement_uses in % name no day (their occurrence is not an occurrence''s resource), for entitlements: %',
                s, dayless;
        END IF;
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlement_uses
                ALTER COLUMN event_id SET NOT NULL,
                DROP CONSTRAINT entitlement_uses_pkey,
                ADD CONSTRAINT entitlement_uses_pkey PRIMARY KEY (entitlement_id, event_id)
        $f$, s);
    END LOOP;
END $$;

COMMIT;
