-- Verify registry:tenant-stripe-connect on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Verify Stripe Connect columns exist on tenants table
SELECT stripe_connect_account_id, stripe_charges_enabled, stripe_details_submitted
FROM tenants LIMIT 1;

ROLLBACK;
