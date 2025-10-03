-- ABOUTME: Migration to create unified pricing infrastructure for tenant-to-tenant relationships
-- ABOUTME: Enables any tenant (including platform) to offer pricing plans to other tenants

-- Deploy registry:unified-pricing-infrastructure to pg
-- requires: simplify-installment-schema-for-stripe

BEGIN;

-- Drop and recreate unified pricing_plans table in registry schema for tenant-to-tenant relationships
DROP TABLE IF EXISTS registry.pricing_plans CASCADE;

CREATE TABLE registry.pricing_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID, -- Optional link to tenant sessions for customer plans
    target_tenant_id UUID REFERENCES registry.tenants(id),
    offering_tenant_id UUID REFERENCES registry.tenants(id),
    plan_scope VARCHAR(20) DEFAULT 'customer'
        CHECK (plan_scope IN ('customer', 'tenant', 'platform')),
    plan_name TEXT NOT NULL,
    plan_type TEXT DEFAULT 'standard',
    pricing_model_type VARCHAR(50) DEFAULT 'fixed'
        CHECK (pricing_model_type IN ('fixed', 'percentage', 'tiered', 'hybrid', 'transaction_fee')),
    amount DECIMAL(10,2) NOT NULL,
    currency TEXT DEFAULT 'USD',
    installments_allowed BOOLEAN DEFAULT false,
    installment_count INTEGER,
    requirements JSONB DEFAULT '{}',
    pricing_configuration JSONB DEFAULT '{}',
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create unified tenant pricing relationships table
CREATE TABLE IF NOT EXISTS registry.tenant_pricing_relationships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payer_tenant_id UUID NOT NULL REFERENCES registry.tenants(id),
    payee_tenant_id UUID NOT NULL REFERENCES registry.tenants(id),
    pricing_plan_id UUID NOT NULL REFERENCES registry.pricing_plans(id),
    relationship_type VARCHAR(50) NOT NULL
        CHECK (relationship_type IN ('platform_fee', 'service_fee', 'revenue_share', 'partnership')),
    started_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT true,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for performance
CREATE INDEX idx_tenant_relationships_payer ON registry.tenant_pricing_relationships(payer_tenant_id);
CREATE INDEX idx_tenant_relationships_payee ON registry.tenant_pricing_relationships(payee_tenant_id);
CREATE INDEX idx_tenant_relationships_active ON registry.tenant_pricing_relationships(is_active) WHERE is_active = true;

-- Universal billing periods (works for all tenant relationships)
CREATE TABLE IF NOT EXISTS registry.billing_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pricing_relationship_id UUID NOT NULL REFERENCES registry.tenant_pricing_relationships(id),
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    calculated_amount DECIMAL(10,2) NOT NULL,
    payment_status VARCHAR(50) DEFAULT 'pending'
        CHECK (payment_status IN ('pending', 'processing', 'paid', 'failed', 'refunded')),
    stripe_invoice_id VARCHAR(255),
    stripe_payment_intent_id VARCHAR(255),
    processed_at TIMESTAMP WITH TIME ZONE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    -- Ensure no overlapping billing periods for the same relationship
    CONSTRAINT no_overlapping_periods UNIQUE(pricing_relationship_id, period_start, period_end)
);

CREATE INDEX idx_billing_periods_relationship ON registry.billing_periods(pricing_relationship_id);
CREATE INDEX idx_billing_periods_status ON registry.billing_periods(payment_status);
CREATE INDEX idx_billing_periods_period ON registry.billing_periods(period_start, period_end);

-- Create the platform tenant if it doesn't exist
INSERT INTO registry.tenants (id, name, slug, billing_status, created_at)
VALUES (
    '00000000-0000-0000-0000-000000000000'::UUID,
    'Registry Platform',
    'registry-platform',
    'active',
    CURRENT_TIMESTAMP
) ON CONFLICT (id) DO NOTHING;

-- Create default platform pricing plans
INSERT INTO registry.pricing_plans (
    id,
    offering_tenant_id,
    plan_scope,
    plan_name,
    plan_type,
    pricing_model_type,
    amount,
    currency,
    pricing_configuration,
    metadata
) VALUES
    -- Revenue share plan
    (
        gen_random_uuid(),
        '00000000-0000-0000-0000-000000000000'::UUID,
        'tenant',
        'Registry Revenue Share - 2%',
        'revenue_share',
        'percentage',
        0.02,
        'USD',
        '{"percentage": 0.02, "applies_to": "customer_payments", "minimum_monthly": 0}'::JSONB,
        '{"description": "2% of all customer payments, no minimums", "default": false}'::JSONB
    ),
    -- Flat fee plan (current default)
    (
        gen_random_uuid(),
        '00000000-0000-0000-0000-000000000000'::UUID,
        'tenant',
        'Registry Standard - $200/month',
        'subscription',
        'fixed',
        200.00,
        'USD',
        '{"monthly_amount": 200.00, "includes": ["unlimited_programs", "unlimited_enrollments", "email_support"]}'::JSONB,
        '{"description": "Standard monthly subscription", "default": true}'::JSONB
    ),
    -- Hybrid plan
    (
        gen_random_uuid(),
        '00000000-0000-0000-0000-000000000000'::UUID,
        'tenant',
        'Registry Plus - $100/month + 1%',
        'hybrid',
        'hybrid',
        100.00,
        'USD',
        '{"monthly_base": 100.00, "percentage": 0.01, "applies_to": "customer_payments"}'::JSONB,
        '{"description": "Reduced monthly fee with revenue share", "default": false}'::JSONB
    );

-- Migration helper: Convert existing subscriptions to new relationships
-- This preserves existing billing while transitioning to the new system
DO $$
DECLARE
    tenant_record RECORD;
    default_plan_id UUID;
BEGIN
    -- Get the default platform plan (Registry Standard)
    SELECT id INTO default_plan_id
    FROM registry.pricing_plans
    WHERE offering_tenant_id = '00000000-0000-0000-0000-000000000000'::UUID
      AND metadata->>'default' = 'true'
    LIMIT 1;

    -- Create relationships for all existing tenants with active subscriptions
    FOR tenant_record IN
        SELECT id, stripe_subscription_id, billing_status, trial_ends_at, subscription_started_at
        FROM registry.tenants
        WHERE stripe_subscription_id IS NOT NULL
          AND id != '00000000-0000-0000-0000-000000000000'::UUID
    LOOP
        INSERT INTO registry.tenant_pricing_relationships (
            payer_tenant_id,
            payee_tenant_id,
            pricing_plan_id,
            relationship_type,
            started_at,
            is_active,
            metadata
        ) VALUES (
            tenant_record.id,
            '00000000-0000-0000-0000-000000000000'::UUID,
            default_plan_id,
            'platform_fee',
            COALESCE(tenant_record.subscription_started_at, CURRENT_TIMESTAMP),
            tenant_record.billing_status IN ('active', 'trial'),
            jsonb_build_object(
                'migrated_from_subscription', true,
                'original_stripe_subscription_id', tenant_record.stripe_subscription_id,
                'original_billing_status', tenant_record.billing_status,
                'trial_ends_at', tenant_record.trial_ends_at
            )
        );
    END LOOP;
END $$;

-- Add triggers for updated_at columns
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_tenant_pricing_relationships_updated_at
    BEFORE UPDATE ON registry.tenant_pricing_relationships
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_billing_periods_updated_at
    BEFORE UPDATE ON registry.billing_periods
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Grant permissions (web role may not exist in test environment)
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'web') THEN
        GRANT SELECT, INSERT, UPDATE ON registry.tenant_pricing_relationships TO web;
        GRANT SELECT, INSERT, UPDATE ON registry.billing_periods TO web;
    END IF;
END $$;

COMMIT;