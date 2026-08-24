-- ABOUTME: Drop the typed obligation columns and the payments.status CHECK.
-- ABOUTME: The jsonb keys were never removed, so nothing has to be written back.

-- Revert registry:payments-typed-obligation from pg

BEGIN;

SET client_min_messages = 'warning';

-- No data restoration, and that is LOSSY for anything recorded after deploy.
--
-- The deploy backfills FROM metadata and leaves those keys in place, so a row
-- that predates the deploy can be reconstructed from the jsonb. But from the
-- moment this change lands, record_capacity_obligation writes only the columns
-- -- no metadata at all -- so every obligation recorded afterwards exists
-- solely here and is erased by this revert. Asymmetrically: _apply_refund_result
-- still writes refund_amount_cents into metadata, so what was PAID survives a
-- revert while what is OWED does not.
--
-- Worse on a redeploy. The frozen metadata keys stay pinned at their
-- pre-migration values while the columns move, so re-deploying re-reads them
-- and resurrects a debt that has since been settled in full -- as an UNSETTLED
-- increment, under the same idempotency key the first attempt used. Stripe
-- dedupes that for 24 hours and not a minute longer.
--
-- Before reverting: dump payments.refund_owed_cents, refunded_cents and
-- refund_increments for every row where refund_owed_cents > 0, in every schema.
-- Before redeploying a reverted database: reconcile the metadata keys against
-- that dump, or clear them.

ALTER TABLE registry.payments
    DROP CONSTRAINT IF EXISTS payments_status_check,
    DROP CONSTRAINT IF EXISTS payments_refund_owed_cents_check,
    DROP CONSTRAINT IF EXISTS payments_refunded_cents_check,
    DROP CONSTRAINT IF EXISTS payments_refund_total_check,
    DROP CONSTRAINT IF EXISTS payments_refund_increments_is_array,
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
                DROP CONSTRAINT IF EXISTS payments_refund_total_check,
                DROP CONSTRAINT IF EXISTS payments_refund_increments_is_array,
                DROP CONSTRAINT IF EXISTS payments_refund_seq_check', s);

        -- By name is not enough: clone_schema renames this index to
        -- payments_refund_owed_cents_idx, so the hardcoded name misses exactly
        -- the tenants that reach production through normal provisioning. It has
        -- only ever worked because the DROP COLUMN below cascades -- a
        -- load-bearing accident.
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_payments_refund_owed', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.payments_refund_owed_cents_idx', s);

        EXECUTE format(
            'ALTER TABLE %I.payments
                DROP COLUMN IF EXISTS refund_owed_cents,
                DROP COLUMN IF EXISTS refunded_cents,
                DROP COLUMN IF EXISTS refund_seq,
                DROP COLUMN IF EXISTS refund_increments', s);
    END LOOP;
END $$;

COMMIT;
