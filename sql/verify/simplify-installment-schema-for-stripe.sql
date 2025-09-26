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

-- Verify past_due status is allowed
INSERT INTO registry.payment_schedules (
    enrollment_id, pricing_plan_id, total_amount, installment_amount,
    installment_count, status
) VALUES (
    gen_random_uuid(), gen_random_uuid(), 100.00, 50.00, 2, 'past_due'
);

-- Clean up test record
ROLLBACK;

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
DO $$
BEGIN
    INSERT INTO registry.scheduled_payments (
        payment_schedule_id, installment_number, amount, status
    ) VALUES (
        gen_random_uuid(), 1, 50.00, 'processing'
    );
    RAISE EXCEPTION 'Should not allow processing status';
EXCEPTION
    WHEN check_violation THEN
        -- This is expected
        NULL;
END $$;