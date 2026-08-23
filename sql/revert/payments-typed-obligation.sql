-- ABOUTME: Drop the typed obligation columns and the payments.status CHECK.
-- ABOUTME: The jsonb keys were never removed, so nothing has to be written back.

-- Revert registry:payments-typed-obligation from pg

BEGIN;

SET client_min_messages = 'warning';

-- No data restoration. The deploy backfilled FROM metadata and left those keys
-- in place, so the jsonb is still the record and dropping the columns loses
-- nothing. This is the reason the deploy does not delete them: a revert that
-- has to reconstruct money is a revert nobody dares run.

ALTER TABLE registry.payments
    DROP CONSTRAINT IF EXISTS payments_status_check,
    DROP CONSTRAINT IF EXISTS payments_refund_owed_cents_check,
    DROP CONSTRAINT IF EXISTS payments_refunded_cents_check,
    DROP CONSTRAINT IF EXISTS payments_refund_seq_check;

DROP INDEX IF EXISTS registry.idx_payments_refund_owed;

ALTER TABLE registry.payments
    DROP COLUMN IF EXISTS refund_owed_cents,
    DROP COLUMN IF EXISTS refunded_cents,
    DROP COLUMN IF EXISTS refund_seq,
    DROP COLUMN IF EXISTS refund_increments;

-- The tenant loop must mirror the deploy's. sql/revert/refund-amounts-cents.sql
-- is the cautionary example: its tenant loop omitted a COMMENT the registry
-- branch restored, and clone_schema's LIKE ... INCLUDING ALL copied the stale
-- comment into every tenant made afterwards.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.payments
                DROP CONSTRAINT IF EXISTS payments_status_check,
                DROP CONSTRAINT IF EXISTS payments_refund_owed_cents_check,
                DROP CONSTRAINT IF EXISTS payments_refunded_cents_check,
                DROP CONSTRAINT IF EXISTS payments_refund_seq_check', s);

        EXECUTE format('DROP INDEX IF EXISTS %I.idx_payments_refund_owed', s);

        EXECUTE format(
            'ALTER TABLE %I.payments
                DROP COLUMN IF EXISTS refund_owed_cents,
                DROP COLUMN IF EXISTS refunded_cents,
                DROP COLUMN IF EXISTS refund_seq,
                DROP COLUMN IF EXISTS refund_increments', s);
    END LOOP;
END $$;

COMMIT;
