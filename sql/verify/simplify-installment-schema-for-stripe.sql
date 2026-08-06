-- Verify registry:simplify-installment-schema-for-stripe on pg

BEGIN;

SET search_path TO registry, public;

-- Verify payment_schedules columns were removed
SELECT 1 / (
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'registry'
        AND table_name = 'payment_schedules'
        AND column_name IN ('first_payment_date', 'frequency')
    ) THEN 1 ELSE 0 END
);

-- Verify past_due status is allowed. Asserted against the constraint
-- definition rather than by inserting a row: the money columns are NOT NULL
-- and a later change renames them, so an INSERT here would fail once that
-- change deploys.
SELECT 1 / (
    CASE WHEN EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'registry.payment_schedules'::regclass
        AND conname = 'payment_schedules_status_check'
        AND pg_get_constraintdef(oid) LIKE '%past_due%'
    ) THEN 1 ELSE 0 END
);

-- Verify scheduled_payments columns were removed
SELECT 1 / (
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'registry'
        AND table_name = 'scheduled_payments'
        AND column_name IN ('due_date', 'attempt_count', 'last_attempt_at')
    ) THEN 1 ELSE 0 END
);

-- Verify processing status is no longer allowed
SELECT 1 / (
    CASE WHEN EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'registry.scheduled_payments'::regclass
        AND conname = 'scheduled_payments_status_check'
        AND pg_get_constraintdef(oid) NOT LIKE '%processing%'
    ) THEN 1 ELSE 0 END
);

ROLLBACK;
