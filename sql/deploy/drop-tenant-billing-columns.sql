-- ABOUTME: Drop the platform's subscription-billing columns from registry.tenants and every tenant schema's copy.
-- ABOUTME: What a tenant holds from the platform is its entitlement; these recorded a subscription that no longer exists.

-- Deploy registry:drop-tenant-billing-columns to pg
-- requires: entitlement-stripe-move-adds-dispute-step

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Dropping a column drops its indexes and the billing_status check with it.
-- IF EXISTS throughout: a tenant copy may already lack some of them.
ALTER TABLE tenants
    DROP COLUMN IF EXISTS stripe_customer_id,
    DROP COLUMN IF EXISTS stripe_subscription_id,
    DROP COLUMN IF EXISTS billing_status,
    DROP COLUMN IF EXISTS trial_ends_at,
    DROP COLUMN IF EXISTS subscription_started_at;

-- clone_schema copied the table's structure into every tenant schema.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regclass(format('%I.tenants', s)) IS NULL;
        EXECUTE format(
            'ALTER TABLE %I.tenants
                 DROP COLUMN IF EXISTS stripe_customer_id,
                 DROP COLUMN IF EXISTS stripe_subscription_id,
                 DROP COLUMN IF EXISTS billing_status,
                 DROP COLUMN IF EXISTS trial_ends_at,
                 DROP COLUMN IF EXISTS subscription_started_at', s );
    END LOOP;
END $$;

COMMIT;
