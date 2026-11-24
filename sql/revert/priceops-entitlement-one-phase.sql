-- ABOUTME: Drop the one-schedule-phase exclusion and the entitlement's offer and plan kind everywhere.
-- ABOUTME: Restores the stamp trigger function that froze only the offer version and plan.

-- Revert registry:priceops-entitlement-one-phase from pg

BEGIN;

SET client_min_messages = 'warning';

CREATE OR REPLACE FUNCTION registry.entitlement_stamp() RETURNS trigger AS $t$
DECLARE
    is_draft boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.offer_version_id, NEW.payment_plan_id)
           IS DISTINCT FROM (OLD.offer_version_id, OLD.payment_plan_id)
        THEN
            RAISE EXCEPTION
                'entitlement % keeps the stamp it was sold under: its offer '
                'version and payment plan cannot change.', OLD.id;
        END IF;
        RETURN NEW;
    END IF;
    EXECUTE format('SELECT published_at IS NULL FROM %I.offer_versions WHERE id = $1',
                   TG_TABLE_SCHEMA) INTO is_draft USING NEW.offer_version_id;
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

        -- Columns before the function, so the trigger never sees a row type
        -- without them; dropping them drops the exclusion and both new keys.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlements
                DROP COLUMN offer_id,
                DROP COLUMN plan_kind,
                ADD CONSTRAINT entitlements_payment_plan_fkey
                    FOREIGN KEY (offer_version_id, payment_plan_id)
                    REFERENCES %1$I.offer_version_payment_plans (offer_version_id, id)
        $f$, s);
        EXECUTE format(
            'ALTER TABLE %I.offer_versions DROP CONSTRAINT offer_versions_id_offer_id_key', s);
        EXECUTE format(
            'ALTER TABLE %I.offer_version_payment_plans DROP CONSTRAINT offer_version_payment_plans_offer_version_id_id_kind_key', s);

        IF s != 'registry' AND to_regprocedure(format('%I.entitlement_stamp()', s)) IS NOT NULL THEN
            EXECUTE replace(pg_get_functiondef('registry.entitlement_stamp()'::regprocedure),
                            'FUNCTION registry.entitlement_stamp()',
                            format('FUNCTION %I.entitlement_stamp()', s));
        END IF;
    END LOOP;
END $$;

DROP EXTENSION IF EXISTS btree_gist;

COMMIT;
