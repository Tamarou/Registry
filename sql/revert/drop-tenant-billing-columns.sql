-- ABOUTME: Re-add the tenant billing columns with their original types, default, check and indexes.
-- ABOUTME: The values dropped are not restored; billing_status comes back at its default, 'trial'.

-- Revert registry:drop-tenant-billing-columns from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- As stripe-subscription-integration added them, with the check under the
-- name Postgres gave it there, so a clone made after the revert matches.
ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT,
    ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT,
    ADD COLUMN IF NOT EXISTS billing_status TEXT DEFAULT 'trial'
        CONSTRAINT tenants_billing_status_check
        CHECK (billing_status IN ('trial', 'active', 'past_due', 'cancelled', 'incomplete')),
    ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMP WITH TIME ZONE,
    ADD COLUMN IF NOT EXISTS subscription_started_at TIMESTAMP WITH TIME ZONE;

CREATE INDEX IF NOT EXISTS idx_tenants_stripe_customer ON tenants(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_tenants_stripe_subscription ON tenants(stripe_subscription_id);
CREATE INDEX IF NOT EXISTS idx_tenants_billing_status ON tenants(billing_status);

-- Tenant copies, with the index names clone_schema's LIKE ... INCLUDING ALL gave them.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regclass(format('%I.tenants', s)) IS NULL;
        EXECUTE format(
            $f$ALTER TABLE %1$I.tenants
                 ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT,
                 ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT,
                 ADD COLUMN IF NOT EXISTS billing_status TEXT DEFAULT 'trial'
                     CONSTRAINT tenants_billing_status_check
                     CHECK (billing_status IN ('trial', 'active', 'past_due', 'cancelled', 'incomplete')),
                 ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMP WITH TIME ZONE,
                 ADD COLUMN IF NOT EXISTS subscription_started_at TIMESTAMP WITH TIME ZONE;
               CREATE INDEX IF NOT EXISTS tenants_stripe_customer_id_idx ON %1$I.tenants (stripe_customer_id);
               CREATE INDEX IF NOT EXISTS tenants_stripe_subscription_id_idx ON %1$I.tenants (stripe_subscription_id);
               CREATE INDEX IF NOT EXISTS tenants_billing_status_idx ON %1$I.tenants (billing_status)$f$, s );
    END LOOP;
END $$;

COMMIT;
