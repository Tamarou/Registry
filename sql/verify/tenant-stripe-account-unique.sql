-- ABOUTME: Verify the one-tenant-per-Stripe-account index exists.
-- ABOUTME: Without it a duplicated account id routes Connect events arbitrarily.

-- Verify registry:tenant-stripe-account-unique on pg

BEGIN;

SELECT 1/count(*) FROM pg_indexes
 WHERE schemaname = 'registry' AND indexname = 'tenants_stripe_connect_account_id_key';

ROLLBACK;
