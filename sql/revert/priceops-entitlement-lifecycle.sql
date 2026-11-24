-- ABOUTME: Drop entitlement lifecycle state, ending, payment link, partial refunds and the relaxed period check everywhere.
-- ABOUTME: Restores the stamp trigger function that froze only the stamp, and the period check with no empty ranges.

-- Revert registry:priceops-entitlement-lifecycle from pg

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
        CONTINUE WHEN to_regclass(format('%I.entitlements', s)) IS NULL;

        EXECUTE format('DROP TABLE IF EXISTS %I.entitlement_refunds', s);

        -- Dropping state drops both checks that read it.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlements
                DROP COLUMN state,
                DROP COLUMN ended_at,
                DROP COLUMN ended_reason,
                DROP COLUMN payment_id,
                DROP COLUMN payment_share_cents,
                ADD CONSTRAINT entitlements_in_effect_check CHECK (
                    NOT isempty(in_effect) AND NOT lower_inf(in_effect)
                    AND lower_inc(in_effect) AND NOT upper_inc(in_effect)
                )
        $f$, s);
    END LOOP;
END $$;

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
    FOR s IN SELECT slug::name FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regprocedure(format('%I.entitlement_stamp()', s)) IS NULL;
        EXECUTE replace(pg_get_functiondef('registry.entitlement_stamp()'::regprocedure),
                        'FUNCTION registry.entitlement_stamp()',
                        format('FUNCTION %I.entitlement_stamp()', s));
    END LOOP;
END $$;

COMMIT;
