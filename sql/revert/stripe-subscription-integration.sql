-- Revert registry:stripe-subscription-integration from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Drop subscription events table
DROP TABLE IF EXISTS subscription_events;

-- Remove Stripe columns from tenants
ALTER TABLE tenants DROP COLUMN IF EXISTS stripe_customer_id;
ALTER TABLE tenants DROP COLUMN IF EXISTS stripe_subscription_id;
ALTER TABLE tenants DROP COLUMN IF EXISTS billing_status;
ALTER TABLE tenants DROP COLUMN IF EXISTS trial_ends_at;
ALTER TABLE tenants DROP COLUMN IF EXISTS subscription_started_at;

-- Remove billing columns from tenant_profiles
ALTER TABLE tenant_profiles DROP COLUMN IF EXISTS billing_email;
ALTER TABLE tenant_profiles DROP COLUMN IF EXISTS billing_phone;
ALTER TABLE tenant_profiles DROP COLUMN IF EXISTS billing_address;
ALTER TABLE tenant_profiles DROP COLUMN IF EXISTS organization_type;

COMMIT;