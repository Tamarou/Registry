-- ABOUTME: Drop the one-tenant-per-Stripe-account index.
-- ABOUTME: Connect events then route to an arbitrary tenant if two come to share an account.

-- Revert registry:tenant-stripe-account-unique from pg

BEGIN;

DROP INDEX IF EXISTS registry.tenants_stripe_connect_account_id_key;

COMMIT;
