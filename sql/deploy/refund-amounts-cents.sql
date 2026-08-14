-- ABOUTME: Store refund money as integer cents.
-- ABOUTME: The last two money columns still counted in dollars.

-- Deploy registry:refund-amounts-cents to pg
-- requires: schedule-amounts-cents

BEGIN;

SET client_min_messages = 'warning';

-- Both columns are nullable: NULL means "no refund", which is not the same as
-- a refund of zero, so the backfill leaves NULL alone.

ALTER TABLE registry.enrollments
    ADD COLUMN IF NOT EXISTS refund_amount_cents INTEGER;
UPDATE registry.enrollments
   SET refund_amount_cents = ROUND(refund_amount * 100)::INTEGER
 WHERE refund_amount IS NOT NULL;
ALTER TABLE registry.enrollments DROP COLUMN refund_amount;

COMMENT ON COLUMN registry.enrollments.refund_amount_cents
    IS 'Amount refunded for dropped enrollment, in cents';

ALTER TABLE registry.drop_requests
    ADD COLUMN IF NOT EXISTS refund_amount_requested_cents INTEGER;
UPDATE registry.drop_requests
   SET refund_amount_requested_cents = ROUND(refund_amount_requested * 100)::INTEGER
 WHERE refund_amount_requested IS NOT NULL;
ALTER TABLE registry.drop_requests DROP COLUMN refund_amount_requested;

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
            'ALTER TABLE %I.enrollments
                ADD COLUMN IF NOT EXISTS refund_amount_cents INTEGER', s);
        EXECUTE format(
            'UPDATE %I.enrollments
                SET refund_amount_cents = ROUND(refund_amount * 100)::INTEGER
              WHERE refund_amount IS NOT NULL', s);
        EXECUTE format('ALTER TABLE %I.enrollments DROP COLUMN refund_amount', s);

        EXECUTE format(
            'ALTER TABLE %I.drop_requests
                ADD COLUMN IF NOT EXISTS refund_amount_requested_cents INTEGER', s);
        EXECUTE format(
            'UPDATE %I.drop_requests
                SET refund_amount_requested_cents = ROUND(refund_amount_requested * 100)::INTEGER
              WHERE refund_amount_requested IS NOT NULL', s);
        EXECUTE format(
            'ALTER TABLE %I.drop_requests DROP COLUMN refund_amount_requested', s);
    END LOOP;
END $$;

COMMIT;
