-- ABOUTME: Migration to document enhanced pricing_configuration schema for resource-aware pricing plans
-- ABOUTME: Adds comments and constraints to ensure proper resource allocation structure

-- Deploy registry:resource-aware-pricing-plans to pg
-- requires: unified-pricing-infrastructure

BEGIN;

-- Add comment to document the enhanced pricing_configuration structure
COMMENT ON COLUMN registry.pricing_plans.pricing_configuration IS
'Extended pricing configuration including resource allocations. Structure:
{
  // Pricing configuration (existing)
  "percentage": 0.02,
  "applies_to": "customer_payments",
  "monthly_base": 100.00,

  // Resource allocations (new)
  "resources": {
    "classes_per_month": 10,
    "sessions_per_program": 5,
    "api_calls_per_day": 1000,
    "storage_gb": 50,
    "bandwidth_gb": 100,
    "max_students": 100,
    "staff_accounts": 5,
    "family_members": 10,
    "admin_accounts": 2,
    "concurrent_users": 50,
    "features": ["attendance_tracking", "payment_processing", "email_notifications"],
    "geographic_scope": ["US", "CA"]
  },

  // Quota policies (new)
  "quotas": {
    "reset_period": "monthly",
    "rollover_allowed": false,
    "overage_policy": "block",
    "overage_rate": 0.05
  },

  // Business rules (new)
  "rules": {
    "auto_renew": true,
    "renewal_notice_days": 30,
    "cancellation_notice_days": 7,
    "refund_policy": "prorated",
    "trial_enabled": true,
    "trial_days": 7,
    "trial_features": "full",
    "prorate_on_upgrade": true,
    "prorate_on_downgrade": true
  }
}';

-- Add comment to document the enhanced requirements structure
COMMENT ON COLUMN registry.pricing_plans.requirements IS
'Eligibility requirements and discount configurations. Structure:
{
  // Age restrictions
  "min_age": 5,
  "max_age": 18,

  // Location restrictions
  "location_restrictions": ["10001", "10002"],

  // Prerequisites
  "required_memberships": ["premium_member"],
  "prerequisite_programs": ["uuid-1", "uuid-2"],

  // Early bird discount
  "early_bird_enabled": true,
  "early_bird_discount": 10,
  "early_bird_cutoff_date": "2024-05-01",

  // Family/group discounts
  "family_discount_enabled": true,
  "min_children": 2,
  "family_discount_type": "percentage",
  "family_discount_amount": 15,

  // Volume discounts
  "volume_discount_enabled": true,
  "volume_tiers": [
    {"min_quantity": 5, "max_quantity": 10, "discount": 5},
    {"min_quantity": 11, "max_quantity": 20, "discount": 10}
  ]
}';

-- Create an index on the plan_scope for faster filtering
CREATE INDEX IF NOT EXISTS idx_pricing_plans_scope ON registry.pricing_plans(plan_scope);

-- Create an index on offering_tenant_id for tenant-specific queries
CREATE INDEX IF NOT EXISTS idx_pricing_plans_offering_tenant ON registry.pricing_plans(offering_tenant_id);

-- Create a partial index for active plans (stored in metadata)
CREATE INDEX IF NOT EXISTS idx_pricing_plans_active ON registry.pricing_plans((metadata->>'is_active'))
WHERE (metadata->>'is_active')::boolean = true;

-- Add check constraint to ensure valid plan_scope values (if not already present)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'valid_plan_scope'
        AND conrelid = 'registry.pricing_plans'::regclass
    ) THEN
        ALTER TABLE registry.pricing_plans
        ADD CONSTRAINT valid_plan_scope
        CHECK (plan_scope IN ('customer', 'tenant', 'platform'));
    END IF;
END$$;

-- Add check constraint to ensure valid pricing_model_type values (if not already present)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'valid_pricing_model_type'
        AND conrelid = 'registry.pricing_plans'::regclass
    ) THEN
        ALTER TABLE registry.pricing_plans
        ADD CONSTRAINT valid_pricing_model_type
        CHECK (pricing_model_type IN ('fixed', 'percentage', 'tiered', 'hybrid', 'transaction_fee', 'usage_based'));
    END IF;
END$$;

-- Function to validate resource allocation structure
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

-- Add trigger to validate resource allocation on insert/update
DROP TRIGGER IF EXISTS validate_pricing_resources_trigger ON registry.pricing_plans;
CREATE TRIGGER validate_pricing_resources_trigger
    BEFORE INSERT OR UPDATE ON registry.pricing_plans
    FOR EACH ROW
    EXECUTE FUNCTION registry.validate_pricing_resources();

COMMIT;