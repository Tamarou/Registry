-- Verify registry:stripe-subscription-integration on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Verify Stripe columns exist on tenants table
SELECT stripe_customer_id, stripe_subscription_id, billing_status, trial_ends_at, subscription_started_at
FROM tenants LIMIT 1;

-- Verify billing columns exist on tenant_profiles table
SELECT billing_email, billing_phone, billing_address, organization_type
FROM tenant_profiles LIMIT 1;

-- Verify subscription_events table exists
SELECT id, tenant_id, stripe_event_id, event_type, event_data, processed_at, processing_status
FROM subscription_events LIMIT 1;

ROLLBACK;