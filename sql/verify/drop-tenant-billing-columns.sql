-- ABOUTME: Verify no tenants table, in registry or any tenant schema, keeps a billing column.
-- ABOUTME: Checked across tenants, because clone_schema promises structurally identical copies.

-- Verify registry:drop-tenant-billing-columns on pg

BEGIN;

DO $$
DECLARE
    found text;
BEGIN
    SELECT string_agg(table_schema || '.' || column_name, ', ') INTO found
      FROM information_schema.columns
     WHERE table_name = 'tenants'
       AND column_name IN ('stripe_customer_id', 'stripe_subscription_id', 'billing_status',
                           'trial_ends_at', 'subscription_started_at');
    IF found IS NOT NULL THEN
        RAISE EXCEPTION 'tenant billing columns remain: %', found;
    END IF;
END $$;

ROLLBACK;
