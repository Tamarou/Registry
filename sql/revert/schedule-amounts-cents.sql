-- ABOUTME: Restore installment schedule money to DECIMAL(10,2) dollars.
-- ABOUTME: Cents divide back exactly; DECIMAL(10,2) holds every value they can carry.

-- Revert registry:schedule-amounts-cents from pg

BEGIN;

SET client_min_messages = 'warning';

ALTER TABLE registry.payment_schedules
    ADD COLUMN IF NOT EXISTS total_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS installment_amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payment_schedules
   SET total_amount = total_amount_cents::DECIMAL / 100,
       installment_amount = installment_amount_cents::DECIMAL / 100;
ALTER TABLE registry.payment_schedules
    DROP COLUMN total_amount_cents,
    DROP COLUMN installment_amount_cents;

ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_amount CHECK (installment_amount > 0);
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_total_amount CHECK (total_amount > 0);

ALTER TABLE registry.scheduled_payments
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.scheduled_payments SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.scheduled_payments DROP COLUMN amount_cents;

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_scheduled_amount CHECK (amount > 0);

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                ADD COLUMN IF NOT EXISTS total_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS installment_amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payment_schedules
                SET total_amount = total_amount_cents::DECIMAL / 100,
                    installment_amount = installment_amount_cents::DECIMAL / 100', s);
        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                DROP COLUMN total_amount_cents,
                DROP COLUMN installment_amount_cents', s);
        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                ADD CONSTRAINT check_installment_amount CHECK (installment_amount > 0)', s);
        EXECUTE format(
            'ALTER TABLE %I.payment_schedules
                ADD CONSTRAINT check_total_amount CHECK (total_amount > 0)', s);

        EXECUTE format(
            'ALTER TABLE %I.scheduled_payments
                ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.scheduled_payments SET amount = amount_cents::DECIMAL / 100', s);
        EXECUTE format('ALTER TABLE %I.scheduled_payments DROP COLUMN amount_cents', s);
        EXECUTE format(
            'ALTER TABLE %I.scheduled_payments
                ADD CONSTRAINT check_scheduled_amount CHECK (amount > 0)', s);
    END LOOP;
END $$;

COMMIT;
