-- ABOUTME: One schedule phase in effect at a time per holder and offer, as an exclusion constraint.
-- ABOUTME: Entitlements carry their offer, copied from the stamped version and frozen with it, as the key.

-- Deploy registry:priceops-entitlement-one-phase to pg
-- requires: priceops-entitlements

BEGIN;

SET client_min_messages = 'warning';

-- `=` on uuid inside a gist exclusion constraint.
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;

-- The stamp now includes the offer, copied from the stamped version at insert
-- (an EXCLUDE cannot join to offer_versions) and frozen with the rest.
CREATE OR REPLACE FUNCTION registry.entitlement_stamp() RETURNS trigger AS $t$
DECLARE
    is_draft boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.offer_version_id, NEW.payment_plan_id, NEW.offer_id)
           IS DISTINCT FROM (OLD.offer_version_id, OLD.payment_plan_id, OLD.offer_id)
        THEN
            RAISE EXCEPTION
                'entitlement % keeps the stamp it was sold under: its offer, '
                'offer version and payment plan cannot change.', OLD.id;
        END IF;
        RETURN NEW;
    END IF;
    EXECUTE format('SELECT published_at IS NULL, offer_id FROM %I.offer_versions WHERE id = $1',
                   TG_TABLE_SCHEMA) INTO is_draft, NEW.offer_id USING NEW.offer_version_id;
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

        EXECUTE format($f$
            ALTER TABLE %1$I.offer_versions
                ADD CONSTRAINT offer_versions_id_offer_key UNIQUE (id, offer_id)
        $f$, s);

        EXECUTE format('ALTER TABLE %I.entitlements ADD COLUMN offer_id uuid', s);
        EXECUTE format($f$
            UPDATE %1$I.entitlements e SET offer_id = v.offer_id
              FROM %1$I.offer_versions v WHERE v.id = e.offer_version_id
        $f$, s);

        -- A holder has one phase of an offer's schedule in effect at a time:
        -- moving to a newer version ends the old phase where the new begins.
        -- Periods are half-open, so a phase ending at T and one starting at T
        -- do not overlap.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlements
                ALTER COLUMN offer_id SET NOT NULL,
                ADD CONSTRAINT entitlements_offer_fkey
                    FOREIGN KEY (offer_version_id, offer_id)
                    REFERENCES %1$I.offer_versions (id, offer_id),
                ADD CONSTRAINT entitlements_one_schedule_phase EXCLUDE USING gist (
                    (coalesce(holder_user_id, holder_family_member_id, holder_tenant_id)) WITH =,
                    offer_id WITH =,
                    in_effect WITH &&
                )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
