-- Revert stripe-connect-accounts

BEGIN;

DROP TABLE IF EXISTS registry.tenant_stripe_accounts;

-- Restore old subscription columns
ALTER TABLE registry.tenants ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT;
ALTER TABLE registry.tenants ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT;
ALTER TABLE registry.tenants ADD COLUMN IF NOT EXISTS billing_status TEXT DEFAULT 'trial';
ALTER TABLE registry.tenants ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE registry.tenants ADD COLUMN IF NOT EXISTS subscription_started_at TIMESTAMP WITH TIME ZONE;

COMMIT;
