-- ABOUTME: Each entitlement records the /terms version its booker agreed to, in registry and every tenant schema.
-- ABOUTME: Set only at insert, like the stamp: entitlement_stamp refuses any change; empty for what no booker agreed to.

-- Deploy registry:entitlement-terms-version to pg
-- requires: location-time-zone

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
        -- NULL where no booker agreed to terms: existing rows, platform terms, grants.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlements
                ADD COLUMN terms_version text
                    CONSTRAINT entitlements_terms_version_check CHECK (terms_version <> '')
        $f$, s);
    END LOOP;
END $$;

-- The stamp, the payment link and now the terms version stay as inserted.
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
        IF (NEW.payment_id, NEW.payment_share_cents)
           IS DISTINCT FROM (OLD.payment_id, OLD.payment_share_cents)
        THEN
            RAISE EXCEPTION
                'entitlement % keeps the payment that created it and its share: '
                'the payment link is set only at insert.', OLD.id;
        END IF;
        IF NEW.terms_version IS DISTINCT FROM OLD.terms_version THEN
            RAISE EXCEPTION
                'entitlement % keeps the terms version its booker agreed to: '
                'it is set only at insert.', OLD.id;
        END IF;
        IF OLD.state <> 'active'
           AND (NEW.state, NEW.ended_at, NEW.ended_reason, NEW.in_effect)
               IS DISTINCT FROM (OLD.state, OLD.ended_at, OLD.ended_reason, OLD.in_effect)
        THEN
            RAISE EXCEPTION
                'entitlement % ended as % (%): an ended entitlement keeps its first ending.',
                OLD.id, OLD.state, OLD.ended_reason;
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

-- clone_schema gave each tenant its own copy, which its trigger calls.
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
