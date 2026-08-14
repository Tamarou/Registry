-- ABOUTME: Store installment schedule money as integer cents.
-- ABOUTME: Keeps the schedule in the same units as the payments it settles.

-- Deploy registry:schedule-amounts-cents to pg
-- requires: payments-amount-cents

BEGIN;

SET client_min_messages = 'warning';

-- Dropping a column drops the CHECK constraints that reference it, so the
-- positive-amount rules are re-declared against the cents columns below.

ALTER TABLE registry.payment_schedules
    ADD COLUMN IF NOT EXISTS total_amount_cents INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS installment_amount_cents INTEGER NOT NULL DEFAULT 0;
UPDATE registry.payment_schedules
   SET total_amount_cents = ROUND(total_amount * 100)::INTEGER,
       installment_amount_cents = ROUND(installment_amount * 100)::INTEGER;
ALTER TABLE registry.payment_schedules
    DROP COLUMN total_amount,
    DROP COLUMN installment_amount;

ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_amount CHECK (installment_amount_cents > 0);
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_total_amount CHECK (total_amount_cents > 0);

ALTER TABLE registry.scheduled_payments
    ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0;
UPDATE registry.scheduled_payments SET amount_cents = ROUND(amount * 100)::INTEGER;
ALTER TABLE registry.scheduled_payments DROP COLUMN amount;

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_scheduled_amount CHECK (amount_cents > 0);

-- clone_schema copies registry at call time, so new tenants pick this up for
-- free. Existing tenant schemas have to be walked.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Skip tenants that don't have their own schema (e.g. registry-platform)
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                ADD COLUMN IF NOT EXISTS total_amount_cents INTEGER NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS installment_amount_cents INTEGER NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payment_schedules
                SET total_amount_cents = ROUND(total_amount * 100)::INTEGER,
                    installment_amount_cents = ROUND(installment_amount * 100)::INTEGER', s);
        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                DROP COLUMN total_amount,
                DROP COLUMN installment_amount', s);
        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                ADD CONSTRAINT check_installment_amount CHECK (installment_amount_cents > 0)', s);
        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                ADD CONSTRAINT check_total_amount CHECK (total_amount_cents > 0)', s);

        EXECUTE format(
            'ALTER TABLE %I.scheduled_payments
                ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.scheduled_payments SET amount_cents = ROUND(amount * 100)::INTEGER', s);
        EXECUTE format('ALTER TABLE %I.scheduled_payments DROP COLUMN amount', s);
        EXECUTE format(
            'ALTER TABLE %I.scheduled_payments
                ADD CONSTRAINT check_scheduled_amount CHECK (amount_cents > 0)', s);
    END LOOP;
END $$;

COMMIT;
