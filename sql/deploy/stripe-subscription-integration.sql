-- Deploy registry:stripe-subscription-integration to pg
-- requires: enhanced-pricing-model

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Add Stripe-related columns to tenants table
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS billing_status TEXT DEFAULT 'trial' 
    CHECK (billing_status IN ('trial', 'active', 'past_due', 'cancelled', 'incomplete'));
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS subscription_started_at TIMESTAMP WITH TIME ZONE;

-- Add billing information to tenant_profiles
ALTER TABLE tenant_profiles ADD COLUMN IF NOT EXISTS billing_email TEXT;
ALTER TABLE tenant_profiles ADD COLUMN IF NOT EXISTS billing_phone TEXT;
ALTER TABLE tenant_profiles ADD COLUMN IF NOT EXISTS billing_address JSONB;
ALTER TABLE tenant_profiles ADD COLUMN IF NOT EXISTS organization_type TEXT;

-- Create subscription events table for webhook tracking
CREATE TABLE IF NOT EXISTS subscription_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES tenants (id),
    stripe_event_id TEXT NOT NULL UNIQUE,
    event_type TEXT NOT NULL,
    event_data JSONB NOT NULL,
    processed_at TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp,
    processing_status TEXT DEFAULT 'pending' 
        CHECK (processing_status IN ('pending', 'processed', 'failed'))
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_tenants_stripe_customer ON tenants(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_tenants_stripe_subscription ON tenants(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_tenants_billing_status ON tenants(billing_status);
CREATE INDEX IF NOT EXISTS idx_subscription_events_tenant ON subscription_events(tenant_id);
CREATE INDEX IF NOT EXISTS idx_subscription_events_status ON subscription_events(processing_status);

COMMIT;