-- ABOUTME: Fix validation trigger to handle NULL values gracefully
-- ABOUTME: Prevents database connection termination when creating minimal pricing plans

-- Deploy registry:fix-pricing-validation-trigger to pg
-- requires: resource-aware-pricing-plans

BEGIN;

-- Updated function to handle NULL values gracefully
CREATE OR REPLACE FUNCTION registry.validate_pricing_resources()
RETURNS trigger AS $$
BEGIN
    -- Validate resources if present
    IF NEW.pricing_configuration ? 'resources' THEN
        -- Check that numeric values are non-negative, handling NULL values
        IF (NEW.pricing_configuration->'resources'->>'classes_per_month') IS NOT NULL AND
           (NEW.pricing_configuration->'resources'->>'classes_per_month')::int < 0 THEN
            RAISE EXCEPTION 'classes_per_month must be non-negative';
        END IF;

        IF (NEW.pricing_configuration->'resources'->>'api_calls_per_day') IS NOT NULL AND
           (NEW.pricing_configuration->'resources'->>'api_calls_per_day')::int < 0 THEN
            RAISE EXCEPTION 'api_calls_per_day must be non-negative';
        END IF;

        IF (NEW.pricing_configuration->'resources'->>'storage_gb') IS NOT NULL AND
           (NEW.pricing_configuration->'resources'->>'storage_gb')::int < 0 THEN
            RAISE EXCEPTION 'storage_gb must be non-negative';
        END IF;
    END IF;

    -- Validate quotas if present
    IF NEW.pricing_configuration ? 'quotas' THEN
        IF (NEW.pricing_configuration->'quotas'->>'reset_period') IS NOT NULL AND
           NOT (NEW.pricing_configuration->'quotas'->>'reset_period') IN
           ('daily', 'weekly', 'monthly', 'quarterly', 'yearly') THEN
            RAISE EXCEPTION 'Invalid reset_period value';
        END IF;

        IF (NEW.pricing_configuration->'quotas'->>'overage_policy') IS NOT NULL AND
           NOT (NEW.pricing_configuration->'quotas'->>'overage_policy') IN
           ('block', 'notify', 'charge', 'throttle') THEN
            RAISE EXCEPTION 'Invalid overage_policy value';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMIT;