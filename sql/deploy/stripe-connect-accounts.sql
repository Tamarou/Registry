-- Deploy stripe-connect-accounts
-- requires: stripe-subscription-integration

BEGIN;

-- New table for Stripe Connect account state per tenant
CREATE TABLE IF NOT EXISTS registry.tenant_stripe_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES registry.tenants(id) ON DELETE CASCADE,
    stripe_account_id TEXT NOT NULL,
    onboarding_status TEXT NOT NULL DEFAULT 'not_started'
        CHECK (onboarding_status IN ('not_started', 'pending', 'complete')),
    charges_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    payouts_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    details_submitted BOOLEAN NOT NULL DEFAULT FALSE,
    account_type TEXT NOT NULL DEFAULT 'standard'
        CHECK (account_type IN ('standard', 'express', 'custom')),
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(tenant_id),
    UNIQUE(stripe_account_id)
);

CREATE INDEX idx_tenant_stripe_accounts_tenant_id ON registry.tenant_stripe_accounts(tenant_id);
CREATE INDEX idx_tenant_stripe_accounts_stripe_id ON registry.tenant_stripe_accounts(stripe_account_id);

-- Remove old subscription columns from tenants table (no production data exists)
ALTER TABLE registry.tenants DROP COLUMN IF EXISTS stripe_customer_id;
ALTER TABLE registry.tenants DROP COLUMN IF EXISTS stripe_subscription_id;
ALTER TABLE registry.tenants DROP COLUMN IF EXISTS billing_status;
ALTER TABLE registry.tenants DROP COLUMN IF EXISTS trial_ends_at;
ALTER TABLE registry.tenants DROP COLUMN IF EXISTS subscription_started_at;

COMMIT;
