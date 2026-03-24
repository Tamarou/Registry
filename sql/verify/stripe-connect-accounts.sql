-- Verify stripe-connect-accounts

BEGIN;

SELECT id, tenant_id, stripe_account_id, onboarding_status,
       charges_enabled, payouts_enabled, details_submitted,
       account_type, metadata, created_at, updated_at
FROM registry.tenant_stripe_accounts WHERE FALSE;

-- Verify old columns are gone
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'registry' AND table_name = 'tenants'
        AND column_name = 'stripe_subscription_id'
    ) THEN
        RAISE EXCEPTION 'stripe_subscription_id column still exists on tenants';
    END IF;
END $$;

ROLLBACK;
