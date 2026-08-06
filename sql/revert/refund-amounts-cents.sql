-- ABOUTME: Restore refund columns to DECIMAL(10,2) dollars.
-- ABOUTME: Cents divide back exactly; NULL stays NULL.

-- Revert registry:refund-amounts-cents from pg

BEGIN;

SET client_min_messages = 'warning';

ALTER TABLE registry.enrollments
    ADD COLUMN IF NOT EXISTS refund_amount DECIMAL(10,2);
UPDATE registry.enrollments
   SET refund_amount = refund_amount_cents::DECIMAL / 100
 WHERE refund_amount_cents IS NOT NULL;
ALTER TABLE registry.enrollments DROP COLUMN refund_amount_cents;

COMMENT ON COLUMN registry.enrollments.refund_amount
    IS 'Amount refunded for dropped enrollment';

ALTER TABLE registry.drop_requests
    ADD COLUMN IF NOT EXISTS refund_amount_requested DECIMAL(10,2);
UPDATE registry.drop_requests
   SET refund_amount_requested = refund_amount_requested_cents::DECIMAL / 100
 WHERE refund_amount_requested_cents IS NOT NULL;
ALTER TABLE registry.drop_requests DROP COLUMN refund_amount_requested_cents;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.enrollments
                ADD COLUMN IF NOT EXISTS refund_amount DECIMAL(10,2)', s);
        EXECUTE format(
            'UPDATE %I.enrollments
                SET refund_amount = refund_amount_cents::DECIMAL / 100
              WHERE refund_amount_cents IS NOT NULL', s);
        EXECUTE format('ALTER TABLE %I.enrollments DROP COLUMN refund_amount_cents', s);

        EXECUTE format(
            'ALTER TABLE %I.drop_requests
                ADD COLUMN IF NOT EXISTS refund_amount_requested DECIMAL(10,2)', s);
        EXECUTE format(
            'UPDATE %I.drop_requests
                SET refund_amount_requested = refund_amount_requested_cents::DECIMAL / 100
              WHERE refund_amount_requested_cents IS NOT NULL', s);
        EXECUTE format(
            'ALTER TABLE %I.drop_requests DROP COLUMN refund_amount_requested_cents', s);
    END LOOP;
END $$;

COMMIT;
