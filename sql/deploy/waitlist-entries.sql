-- ABOUTME: A session resource's waitlist: a first-come queue of children, ordered by joined_at then id.
-- ABOUTME: Built in registry and every tenant schema; clone_schema gives new tenants the same.

-- Deploy registry:waitlist-entries to pg
-- requires: entitlement-uses-per-day

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
        CONTINUE WHEN to_regclass(format('%I.resources', s)) IS NULL;

        -- An offer is a seat held for a checkout run: offered entries name both.
        EXECUTE format($f$
            CREATE TABLE %1$I.waitlist_entries (
                id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                resource_id      uuid NOT NULL REFERENCES %1$I.resources (id),
                family_member_id uuid NOT NULL REFERENCES %1$I.family_members (id),
                payer_user_id    uuid NOT NULL REFERENCES %1$I.users (id),
                joined_at        timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
                state            text NOT NULL DEFAULT 'waiting'
                    CHECK (state IN ('waiting', 'offered', 'accepted', 'lapsed', 'left')),
                hold_id          uuid REFERENCES %1$I.holds (id),
                workflow_run_id  uuid REFERENCES %1$I.workflow_runs (id),
                offered_at       timestamp with time zone,
                CONSTRAINT waitlist_entries_offer_is_held CHECK (
                    state != 'offered' OR num_nonnulls(hold_id, workflow_run_id, offered_at) = 3
                )
            )
        $f$, s);
        -- A child is in a session's line at most once. Indexes take default
        -- names, as clone_schema's LIKE ... INCLUDING ALL gives, so every
        -- schema names them alike.
        EXECUTE format($f$
            CREATE UNIQUE INDEX ON %I.waitlist_entries (resource_id, family_member_id)
                WHERE state IN ('waiting', 'offered')
        $f$, s);
        EXECUTE format($f$
            CREATE INDEX ON %I.waitlist_entries (resource_id, joined_at, id) WHERE state = 'waiting'
        $f$, s);
    END LOOP;
END $$;

COMMIT;
