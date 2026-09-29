-- ABOUTME: Instalment offers move from two columns into pricing_configuration, where a shape can be declared.
-- ABOUTME: A boolean and a count could say "in parts" and nothing else -- no cadence, no surcharge.

-- Deploy registry:instalments-declared-in-configuration to pg
-- requires: tenant-created-from-ip

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- installments_allowed/installment_count were collected, validated and stored,
-- and read by nothing in the payment path: a plan configured for three
-- instalments charged the parent in full (#425). Rather than teach the payment
-- path to branch on a boolean -- which is the plan_type anti-pattern Pillar 4
-- forbids, and the one calculate_price was just freed from (#427) -- the offer
-- becomes part of the plan's declared configuration:
--
--     {"schedule": {"count": 3, "cadence": "monthly", "surcharge_pct": 0}}
--
-- so a further payment shape is data rather than another column and another if.
--
-- Nothing is carried across. No plan in any schema has ever had
-- installments_allowed set -- checked before writing this -- because the
-- pricing screen stopped offering the control in #437 and the payment path
-- never honoured it before that. There is no configured instalment plan
-- anywhere to preserve.
DO $$
DECLARE
    s name;
    n bigint;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.pricing_plans', s)) IS NULL;
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = s AND table_name = 'pricing_plans'
               AND column_name = 'installments_allowed'
        );

        -- Refuse rather than discard. If some schema does carry a configured
        -- instalment plan, this migration would silently throw the terms away,
        -- and a plan losing its terms is the thing pricing_plans' immutability
        -- trigger exists to prevent.
        EXECUTE format(
            'SELECT count(*) FROM %I.pricing_plans WHERE installments_allowed', s )
            INTO n;
        IF n > 0 THEN
            RAISE EXCEPTION
                'schema % has % plan(s) with installments_allowed set; migrate them into pricing_configuration->''schedule'' before dropping the columns',
                s, n;
        END IF;

        EXECUTE format(
            'ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS installments_allowed', s );
        EXECUTE format(
            'ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS installment_count', s );
    END LOOP;
END $$;

COMMIT;
