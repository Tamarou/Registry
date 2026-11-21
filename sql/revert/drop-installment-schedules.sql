-- ABOUTME: Recreate the installment schedule tables as they stood at the plan tip.
-- ABOUTME: LOSSY -- structure only; rows dropped by the deploy cannot be recovered.

-- Revert registry:drop-installment-schedules from pg

-- LOSSY REVERT.  The deploy DROPs both tables, so their rows are gone.  This
-- script restores structure exactly -- every column, index, constraint, trigger
-- and comment, in registry and in every tenant schema -- and restores no data.
-- The deploy is gated on both tables being empty in production (see the plan's
-- Step 1a); if that gate was honoured there is nothing to recover.

BEGIN;

SET client_min_messages = 'warning';

CREATE TABLE registry.payment_schedules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    enrollment_id UUID NOT NULL,
    pricing_plan_id UUID NOT NULL,
    stripe_subscription_id VARCHAR(255),
    installment_count INTEGER NOT NULL,
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    total_amount_cents INTEGER NOT NULL DEFAULT 0,
    installment_amount_cents INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE registry.scheduled_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_schedule_id UUID NOT NULL
        REFERENCES registry.payment_schedules(id) ON DELETE CASCADE,
    payment_id UUID REFERENCES registry.payments(id),
    installment_number INTEGER NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    paid_at TIMESTAMP WITH TIME ZONE,
    failed_at TIMESTAMP WITH TIME ZONE,
    failure_reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    amount_cents INTEGER NOT NULL DEFAULT 0
);

-- Named constraints, in the order the original chain created them, so that
-- pg_get_constraintdef output matches name for name.
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT payment_schedules_status_check
    CHECK (status IN ('active', 'completed', 'cancelled', 'suspended', 'past_due'));
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_count CHECK (installment_count > 1);
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_amount CHECK (installment_amount_cents > 0);
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_total_amount CHECK (total_amount_cents > 0);

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT scheduled_payments_status_check
    CHECK (status IN ('pending', 'completed', 'failed', 'cancelled'));
ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_installment_number CHECK (installment_number > 0);
ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_scheduled_amount CHECK (amount_cents > 0);

CREATE INDEX idx_payment_schedules_enrollment
    ON registry.payment_schedules(enrollment_id);
CREATE INDEX idx_payment_schedules_pricing_plan
    ON registry.payment_schedules(pricing_plan_id);
CREATE INDEX idx_payment_schedules_stripe_subscription
    ON registry.payment_schedules(stripe_subscription_id);
CREATE INDEX idx_payment_schedules_status
    ON registry.payment_schedules(status);

CREATE INDEX idx_scheduled_payments_schedule
    ON registry.scheduled_payments(payment_schedule_id);
CREATE INDEX idx_scheduled_payments_payment
    ON registry.scheduled_payments(payment_id);
CREATE INDEX idx_scheduled_payments_status
    ON registry.scheduled_payments(status);

CREATE TRIGGER update_payment_schedules_updated_at
    BEFORE UPDATE ON registry.payment_schedules
    FOR EACH ROW
    EXECUTE FUNCTION registry.update_updated_at_column();

CREATE TRIGGER update_scheduled_payments_updated_at
    BEFORE UPDATE ON registry.scheduled_payments
    FOR EACH ROW
    EXECUTE FUNCTION registry.update_updated_at_column();

COMMENT ON TABLE registry.payment_schedules
    IS 'Payment schedules managed via Stripe subscriptions';
COMMENT ON COLUMN registry.payment_schedules.stripe_subscription_id
    IS 'Stripe subscription ID - required for all schedules';
COMMENT ON TABLE registry.scheduled_payments
    IS 'Individual installment tracking - status updated via Stripe webhooks';

-- Tenant copies.  LIKE ... INCLUDING ALL copies indexes, defaults, checks and
-- comments but NOT foreign keys and NOT triggers, so both are re-added.
-- payment_schedules has no FKs to re-add: enrollment_id and pricing_plan_id
-- are plain UUID NOT NULL in the original migration.
--
-- The triggers fire a function in the TENANT's schema, not registry's.  A
-- clone_schema-provisioned tenant carries its own update_updated_at_column and
-- its triggers bind to that copy; %I.update_updated_at_column() reproduces it.
--
-- The to_regclass guards also skip the seeded 'registry' tenant, whose tables
-- the block above has already created.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        IF to_regclass(format('%I.payment_schedules', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.payment_schedules (LIKE registry.payment_schedules INCLUDING ALL)', s);
            EXECUTE format(
                'CREATE TRIGGER update_payment_schedules_updated_at
                    BEFORE UPDATE ON %I.payment_schedules
                    FOR EACH ROW EXECUTE FUNCTION %I.update_updated_at_column()',
                s, s);
        END IF;

        IF to_regclass(format('%I.scheduled_payments', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.scheduled_payments (LIKE registry.scheduled_payments INCLUDING ALL)', s);
            EXECUTE format(
                'ALTER TABLE %I.scheduled_payments
                    ADD CONSTRAINT scheduled_payments_payment_schedule_id_fkey
                    FOREIGN KEY (payment_schedule_id) REFERENCES %I.payment_schedules(id) ON DELETE CASCADE',
                s, s);
            EXECUTE format(
                'ALTER TABLE %I.scheduled_payments
                    ADD CONSTRAINT scheduled_payments_payment_id_fkey
                    FOREIGN KEY (payment_id) REFERENCES %I.payments(id)',
                s, s);
            EXECUTE format(
                'CREATE TRIGGER update_scheduled_payments_updated_at
                    BEFORE UPDATE ON %I.scheduled_payments
                    FOR EACH ROW EXECUTE FUNCTION %I.update_updated_at_column()',
                s, s);
        END IF;
    END LOOP;
END $$;

COMMIT;
