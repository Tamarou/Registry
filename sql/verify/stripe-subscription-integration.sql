-- Verify registry:stripe-subscription-integration on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Stripe columns on tenants table were moved to tenant_stripe_accounts
-- by the stripe-connect-accounts migration. Verify billing columns on profiles instead.

-- Verify billing columns exist on tenant_profiles table
SELECT billing_email, billing_phone, billing_address, organization_type
FROM tenant_profiles LIMIT 1;

-- Verify subscription_events table exists
SELECT id, tenant_id, stripe_event_id, event_type, event_data, processed_at, processing_status
FROM subscription_events LIMIT 1;

ROLLBACK;