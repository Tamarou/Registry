-- Revert registry:simplify-installment-schema-for-stripe from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Restore frequency and first_payment_date columns
ALTER TABLE registry.payment_schedules
    ADD COLUMN first_payment_date DATE,
    ADD COLUMN frequency VARCHAR(20) DEFAULT 'monthly' CHECK (frequency IN ('monthly', 'weekly', 'bi_weekly'));

-- Restore original status constraint
ALTER TABLE registry.payment_schedules
    DROP CONSTRAINT payment_schedules_status_check;

ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT payment_schedules_status_check
    CHECK (status IN ('active', 'completed', 'cancelled', 'suspended'));

-- Restore retry-related fields
ALTER TABLE registry.scheduled_payments
    ADD COLUMN due_date DATE,
    ADD COLUMN attempt_count INTEGER DEFAULT 0,
    ADD COLUMN last_attempt_at TIMESTAMP WITH TIME ZONE;

-- Restore original status constraint
ALTER TABLE registry.scheduled_payments
    DROP CONSTRAINT scheduled_payments_status_check;

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT scheduled_payments_status_check
    CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled'));

-- Restore indexes
CREATE INDEX idx_scheduled_payments_due_date ON registry.scheduled_payments(due_date);
CREATE INDEX idx_scheduled_payments_processing ON registry.scheduled_payments(status, due_date) WHERE status IN ('pending', 'failed');

COMMIT;