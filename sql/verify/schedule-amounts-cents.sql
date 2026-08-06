-- ABOUTME: Verify installment schedule money carries integer cents, in every schema.
-- ABOUTME: A schedule left in dollars would bill a hundredth of what it owes.

-- Verify registry:schedule-amounts-cents on pg

BEGIN;

DO $$
DECLARE
    s name;
    c text[];
    pair text[];
BEGIN
    -- table, dropped dollars column, required cents column
    FOREACH c SLICE 1 IN ARRAY ARRAY[
        ['payment_schedules', 'total_amount', 'total_amount_cents'],
        ['payment_schedules', 'installment_amount', 'installment_amount_cents'],
        ['scheduled_payments', 'amount', 'amount_cents']
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'registry' AND table_name = c[1]
               AND column_name = c[3] AND data_type = 'integer'
        ) THEN
            RAISE EXCEPTION 'registry.%.% is missing or not an integer', c[1], c[3];
        END IF;

        IF EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'registry' AND table_name = c[1]
               AND column_name = c[2]
        ) THEN
            RAISE EXCEPTION 'registry.%.% still carries dollars', c[1], c[2];
        END IF;

        FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
            CONTINUE WHEN NOT EXISTS (
                SELECT 1 FROM information_schema.schemata WHERE schema_name = s
            );

            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = c[1]
                   AND column_name = c[3]
            ) THEN
                RAISE EXCEPTION 'tenant schema %.%.% was not converted', s, c[1], c[3];
            END IF;
        END LOOP;
    END LOOP;

    -- The positive-amount rules must survive the column swap.
    FOREACH pair SLICE 1 IN ARRAY ARRAY[
        ['payment_schedules', 'check_installment_amount'],
        ['payment_schedules', 'check_total_amount'],
        ['scheduled_payments', 'check_scheduled_amount']
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint con
              JOIN pg_class rel ON rel.oid = con.conrelid
              JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
             WHERE nsp.nspname = 'registry' AND rel.relname = pair[1]
               AND con.conname = pair[2]
        ) THEN
            RAISE EXCEPTION 'registry.% lost constraint %', pair[1], pair[2];
        END IF;
    END LOOP;
END $$;

ROLLBACK;
