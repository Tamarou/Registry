-- ABOUTME: An entitlement's lifecycle state: active, or ended once (expired, refunded, lost to a dispute) with when and why.
-- ABOUTME: Ending closes the period; an ended entitlement never changes again. Built in registry and every tenant schema.

-- Deploy registry:priceops-entitlement-lifecycle to pg
-- requires: priceops-entitlement-units

BEGIN;

SET client_min_messages = 'warning';

-- The stamp stays frozen, and an ended entitlement keeps its first ending:
-- it never returns to active, never moves to another ended state, and its
-- closed period never reopens.
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

        -- Existing rows default to active. An ending closes the period at the
        -- ending time, so the period never overlaps [ended_at, infinity); one
        -- ended before it began is empty, which only an ended state may be.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlements
                ADD COLUMN state text NOT NULL DEFAULT 'active'
                    CONSTRAINT entitlements_state_check
                    CHECK (state IN ('active', 'expired', 'refunded', 'dispute_lost')),
                ADD COLUMN ended_at timestamp with time zone,
                ADD COLUMN ended_reason text,
                ADD CONSTRAINT entitlements_ending_check CHECK (
                    CASE WHEN state = 'active' THEN ended_at IS NULL AND ended_reason IS NULL
                         ELSE ended_at IS NOT NULL AND ended_reason IS NOT NULL
                              AND NOT in_effect && tstzrange(ended_at, NULL)
                    END
                ),
                DROP CONSTRAINT entitlements_in_effect_check,
                ADD CONSTRAINT entitlements_in_effect_check CHECK (
                    CASE WHEN isempty(in_effect) THEN state <> 'active'
                         ELSE NOT lower_inf(in_effect) AND lower_inc(in_effect)
                              AND NOT upper_inc(in_effect)
                    END
                )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
