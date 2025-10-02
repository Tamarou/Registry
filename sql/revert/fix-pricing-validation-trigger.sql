-- ABOUTME: Revert pricing validation trigger fix
-- ABOUTME: Restores original trigger that didn't handle NULL values

-- Revert registry:fix-pricing-validation-trigger from pg

BEGIN;

-- Revert to original function that doesn't handle NULL values
CREATE OR REPLACE FUNCTION registry.validate_pricing_resources()
RETURNS trigger AS $$
BEGIN
    -- Validate resources if present
    IF NEW.pricing_configuration ? 'resources' THEN
        -- Check that numeric values are non-negative
        IF (NEW.pricing_configuration->'resources'->>'classes_per_month')::int < 0 OR
           (NEW.pricing_configuration->'resources'->>'api_calls_per_day')::int < 0 OR
           (NEW.pricing_configuration->'resources'->>'storage_gb')::int < 0 THEN
            RAISE EXCEPTION 'Resource values must be non-negative';
        END IF;
    END IF;

    -- Validate quotas if present
    IF NEW.pricing_configuration ? 'quotas' THEN
        IF NOT (NEW.pricing_configuration->'quotas'->>'reset_period') IN
           ('daily', 'weekly', 'monthly', 'quarterly', 'yearly') THEN
            RAISE EXCEPTION 'Invalid reset_period value';
        END IF;

        IF NOT (NEW.pricing_configuration->'quotas'->>'overage_policy') IN
           ('block', 'notify', 'charge', 'throttle') THEN
            RAISE EXCEPTION 'Invalid overage_policy value';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMIT;