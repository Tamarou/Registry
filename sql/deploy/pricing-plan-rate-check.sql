-- ABOUTME: A plan rate is a fraction from 0 to 1 with at most 4 decimals, required on a rate-charging plan, in every schema.
-- ABOUTME: Refuses, naming the schema, if a plan already breaks the rule, so a person decides its rate.

-- Deploy registry:pricing-plan-rate-check to pg
-- requires: webhook-events-connect-payload

BEGIN;

SET client_min_messages = 'warning';

-- PricingPlan->create checks the rate, but a rate written straight into SQL
-- skipped it, and one with five decimals made application_fee_cents die while
-- creating a payment intent. The same rule, held by the table. A non-numeric
-- rate fails the regex rather than the cast, so it is refused, not an error.
-- A percentage, hybrid or revenue_share plan with no rate dies in _coerce_pct
-- at checkout, so it must have one.
-- clone_schema copies the constraint into tenants created after this.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.pricing_plans', s)) IS NULL;

        -- Refuse rather than fix: which rate a plan should have is a person's call.
        BEGIN
            EXECUTE format(
                'ALTER TABLE %I.pricing_plans ADD CONSTRAINT pricing_plans_percentage_rate_check CHECK (
                    ( pricing_configuration->>''percentage'' IS NULL AND
                      pricing_model_type NOT IN (''percentage'', ''hybrid'', ''revenue_share'') ) OR
                    CASE WHEN pricing_configuration->>''percentage''
                              ~ ''^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$''
                         THEN (pricing_configuration->>''percentage'')::numeric BETWEEN 0 AND 1
                          AND (pricing_configuration->>''percentage'')::numeric
                              = round( (pricing_configuration->>''percentage'')::numeric, 4 )
                         ELSE false
                    END )', s );
        EXCEPTION WHEN check_violation THEN
            RAISE EXCEPTION 'pricing-plan-rate-check: schema % has a pricing plan whose pricing_configuration->>''percentage'' is not a fraction from 0 to 1 with at most 4 decimals, or is missing on a percentage, hybrid or revenue_share plan; correct it and deploy again', s;
        END;
    END LOOP;
END $$;

COMMIT;
