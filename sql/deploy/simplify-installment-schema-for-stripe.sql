-- Deploy registry:simplify-installment-schema-for-stripe to pg
-- requires: installment-payment-schedules

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove fields that are now handled by Stripe
ALTER TABLE registry.payment_schedules
    DROP COLUMN first_payment_date,
    DROP COLUMN frequency;

-- Add past_due status option for Stripe dunning management
ALTER TABLE registry.payment_schedules
    DROP CONSTRAINT payment_schedules_status_check;

ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT payment_schedules_status_check
    CHECK (status IN ('active', 'completed', 'cancelled', 'suspended', 'past_due'));

-- Remove retry-related fields from scheduled payments (Stripe handles retries)
ALTER TABLE registry.scheduled_payments
    DROP COLUMN due_date,
    DROP COLUMN attempt_count,
    DROP COLUMN last_attempt_at;

-- Remove processing status since webhooks handle state transitions
ALTER TABLE registry.scheduled_payments
    DROP CONSTRAINT scheduled_payments_status_check;

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT scheduled_payments_status_check
    CHECK (status IN ('pending', 'completed', 'failed', 'cancelled'));

-- Remove indexes that are no longer needed (if they exist)
DROP INDEX IF EXISTS idx_scheduled_payments_due_date;
DROP INDEX IF EXISTS idx_scheduled_payments_processing;

-- Update comments to reflect Stripe-native approach
COMMENT ON TABLE registry.payment_schedules IS 'Payment schedules managed via Stripe subscriptions';
COMMENT ON COLUMN registry.payment_schedules.stripe_subscription_id IS 'Stripe subscription ID - required for all schedules';

COMMENT ON TABLE registry.scheduled_payments IS 'Individual installment tracking - status updated via Stripe webhooks';

COMMIT;