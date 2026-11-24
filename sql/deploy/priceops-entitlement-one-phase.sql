-- ABOUTME: One schedule phase in effect at a time per holder and offer, as an exclusion constraint.
-- ABOUTME: Entitlements carry their offer and plan kind, copied at insert and frozen with the stamp.

-- Deploy registry:priceops-entitlement-one-phase to pg
-- requires: priceops-entitlements

BEGIN;

SET client_min_messages = 'warning';

-- `=` on uuid inside a gist exclusion constraint.
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;

-- The stamp now includes the offer and the accepted plan's kind, copied at
-- insert (an EXCLUDE cannot join to offer_versions) and frozen with the rest.
CREATE OR REPLACE FUNCTION registry.entitlement_stamp() RETURNS trigger AS $t$
DECLARE
    is_draft boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.offer_version_id, NEW.payment_plan_id, NEW.offer_id, NEW.plan_kind)
           IS DISTINCT FROM (OLD.offer_version_id, OLD.payment_plan_id, OLD.offer_id, OLD.plan_kind)
        THEN
            RAISE EXCEPTION
                'entitlement % keeps the stamp it was sold under: its offer, '
                'offer version, payment plan and its kind cannot change.', OLD.id;
        END IF;
        RETURN NEW;
    END IF;
    EXECUTE format('SELECT published_at IS NULL, offer_id FROM %I.offer_versions WHERE id = $1',
                   TG_TABLE_SCHEMA) INTO is_draft, NEW.offer_id USING NEW.offer_version_id;
    -- No such plan leaves the kind NULL, which the plan foreign key refuses.
    EXECUTE format('SELECT kind FROM %I.offer_version_payment_plans
                     WHERE offer_version_id = $1 AND id = $2', TG_TABLE_SCHEMA)
       INTO NEW.plan_kind USING NEW.offer_version_id, NEW.payment_plan_id;
    IF is_draft THEN
        RAISE EXCEPTION 'offer version % is a draft: nothing is sold under it until it is published',
            NEW.offer_version_id;
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
        CONTINUE WHEN to_regclass(format('%I.entitlements', s)) IS NULL;

        -- clone_schema gave a tenant provisioned since its own copy, which its
        -- trigger calls; bring that copy up to date.
        IF s != 'registry' AND to_regprocedure(format('%I.entitlement_stamp()', s)) IS NOT NULL THEN
            EXECUTE replace(pg_get_functiondef('registry.entitlement_stamp()'::regprocedure),
                            'FUNCTION registry.entitlement_stamp()',
                            format('FUNCTION %I.entitlement_stamp()', s));
        END IF;

        -- Default constraint names throughout: clone_schema copies these
        -- through LIKE ... INCLUDING ALL, which names them the default way, so
        -- every schema names them alike.
        EXECUTE format('ALTER TABLE %I.offer_versions ADD UNIQUE (id, offer_id)', s);
        EXECUTE format(
            'ALTER TABLE %I.offer_version_payment_plans ADD UNIQUE (offer_version_id, id, kind)', s);

        EXECUTE format(
            'ALTER TABLE %I.entitlements ADD COLUMN offer_id uuid, ADD COLUMN plan_kind text', s);
        EXECUTE format($f$
            UPDATE %1$I.entitlements e SET offer_id = v.offer_id, plan_kind = p.kind
              FROM %1$I.offer_versions v
              JOIN %1$I.offer_version_payment_plans p ON p.offer_version_id = v.id
             WHERE v.id = e.offer_version_id AND p.id = e.payment_plan_id
        $f$, s);

        -- A holder has one phase of an offer's schedule in effect at a time:
        -- moving to a newer version ends the old phase where the new begins.
        -- Periods are half-open, so a phase ending at T and one starting at T
        -- do not overlap. Schedule-type is every plan kind but one_time: a
        -- discrete entitlement (a seat) may repeat, so a new discrete kind
        -- must be added to this predicate.
        -- MATCH FULL: a plan kind left NULL by a missing plan is refused, so
        -- the kind always matches the plan accepted.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlements
                ALTER COLUMN offer_id SET NOT NULL,
                ADD CONSTRAINT entitlements_offer_fkey
                    FOREIGN KEY (offer_version_id, offer_id)
                    REFERENCES %1$I.offer_versions (id, offer_id),
                DROP CONSTRAINT entitlements_payment_plan_fkey,
                ADD CONSTRAINT entitlements_payment_plan_fkey
                    FOREIGN KEY (offer_version_id, payment_plan_id, plan_kind)
                    REFERENCES %1$I.offer_version_payment_plans (offer_version_id, id, kind)
                    MATCH FULL,
                ADD EXCLUDE USING gist (
                    (coalesce(holder_user_id, holder_family_member_id, holder_tenant_id)) WITH =,
                    offer_id WITH =,
                    in_effect WITH &&
                ) WHERE (plan_kind <> 'one_time')
        $f$, s);
    END LOOP;
END $$;

COMMIT;
