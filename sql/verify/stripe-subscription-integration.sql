-- Verify registry:stripe-subscription-integration on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- The tenants billing columns this change added are dropped by
-- drop-tenant-billing-columns, whose verify asserts their absence; nothing
-- about them is true both here and at the end of the plan.

-- Verify billing columns exist on tenant_profiles table
SELECT billing_email, billing_phone, billing_address, organization_type
FROM tenant_profiles LIMIT 1;

-- Verify subscription_events table exists
SELECT id, tenant_id, stripe_event_id, event_type, event_data, processed_at, processing_status
FROM subscription_events LIMIT 1;

ROLLBACK;