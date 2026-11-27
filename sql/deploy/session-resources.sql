-- ABOUTME: A session is one finite resource whose days are its events, and a resource may carry a waitlist.
-- ABOUTME: Built in registry and every tenant schema; clone_schema gives new tenants the same.

-- Deploy registry:session-resources to pg
-- requires: template-editor-admin-only

BEGIN;

SET client_min_messages = 'warning';

-- One side of a day and an occurrence never meeting: a resource may not be
-- the occurrence resource of an event that is a session's day, and an event
-- that has an occurrence resource may not become a session's day. A trigger,
-- since a CHECK cannot read another table; it reads its own row's schema so
-- clone_schema's copy works in each tenant.
CREATE FUNCTION registry.session_day_has_no_occurrence() RETURNS trigger AS $t$
DECLARE
    clash boolean;
BEGIN
    IF TG_TABLE_NAME = 'resources' THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.events WHERE id = $1 AND session_resource_id IS NOT NULL)',
                       TG_TABLE_SCHEMA) INTO clash USING NEW.event_id;
    ELSE
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.resources WHERE event_id = $1)', TG_TABLE_SCHEMA)
            INTO clash USING NEW.id;
        clash := clash AND NEW.session_resource_id IS NOT NULL;
    END IF;
    IF clash THEN
        RAISE EXCEPTION 'event % is a session''s day, so it has no occurrence resource',
            CASE TG_TABLE_NAME WHEN 'resources' THEN NEW.event_id ELSE NEW.id END
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

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

        -- The waitlist a finite resource keeps: none, or a queue whose next
        -- family gets a seat held offer_hold_hours.
        EXECUTE format($f$
            ALTER TABLE %1$I.resources
                ADD COLUMN waitlist jsonb NOT NULL DEFAULT '{"kind":"none"}',
                ADD CONSTRAINT resources_waitlist_kind CHECK (
                    waitlist = '{"kind":"none"}'
                    OR (waitlist = jsonb_build_object('kind', 'queue', 'offer_hold_hours', waitlist->'offer_hold_hours')
                        AND jsonb_typeof(waitlist->'offer_hold_hours') = 'number'
                        AND (waitlist->>'offer_hold_hours') ~ '^[1-9][0-9]*$')),
                ADD CONSTRAINT resources_waitlist_queue_is_finite
                    CHECK (waitlist->>'kind' = 'none' OR kind = 'finite')
        $f$, s);

        -- A session's days are its events.
        EXECUTE format($f$
            ALTER TABLE %1$I.events ADD COLUMN session_resource_id uuid REFERENCES %1$I.resources (id)
        $f$, s);
        EXECUTE format('CREATE INDEX events_session_resource_id_idx ON %I.events (session_resource_id)', s);
        EXECUTE format('CREATE TRIGGER resources_session_day_has_no_occurrence BEFORE INSERT OR UPDATE ON %I.resources '
                       'FOR EACH ROW EXECUTE FUNCTION registry.session_day_has_no_occurrence()', s);
        EXECUTE format('CREATE TRIGGER events_session_day_has_no_occurrence BEFORE UPDATE ON %I.events '
                       'FOR EACH ROW EXECUTE FUNCTION registry.session_day_has_no_occurrence()', s);
    END LOOP;
END $$;

COMMIT;
