-- ABOUTME: Verify the typed obligation columns and status CHECK exist in every schema.
-- ABOUTME: A tenant left unconstrained is where the money actually is.

-- Verify registry:payments-typed-obligation on pg

BEGIN;

DO $$
DECLARE
    s name;
    c text;
BEGIN
    FOREACH c IN ARRAY ARRAY['refund_owed_cents', 'refunded_cents', 'refund_seq'] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'registry' AND table_name = 'payments'
               AND column_name = c AND data_type = 'integer'
        ) THEN
            RAISE EXCEPTION 'registry.payments has no integer % column', c;
        END IF;
    END LOOP;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'payments_status_check'
           AND conrelid = 'registry.payments'::regclass
    ) THEN
        RAISE EXCEPTION 'registry.payments.status is unconstrained';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
         WHERE schemaname = 'registry' AND indexname = 'idx_payments_refund_owed'
    ) THEN
        RAISE EXCEPTION 'registry.payments has no refund_owed index';
    END IF;

    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        FOREACH c IN ARRAY ARRAY['refund_owed_cents', 'refunded_cents', 'refund_seq'] LOOP
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = 'payments' AND column_name = c
            ) THEN
                RAISE EXCEPTION 'tenant schema % was not given %', s, c;
            END IF;
        END LOOP;

        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
             WHERE conname = 'payments_status_check'
               AND conrelid = format('%I.payments', s)::regclass
        ) THEN
            RAISE EXCEPTION 'tenant schema %.payments.status is unconstrained', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
