-- ABOUTME: Verify refund money carries integer cents, in every schema.
-- ABOUTME: A refund column left in dollars would refund a hundredth of what is owed.

-- Verify registry:refund-amounts-cents on pg

BEGIN;

DO $$
DECLARE
    s name;
    c text[];
BEGIN
    -- table, dropped dollars column, required cents column
    FOREACH c SLICE 1 IN ARRAY ARRAY[
        ['enrollments', 'refund_amount', 'refund_amount_cents'],
        ['drop_requests', 'refund_amount_requested', 'refund_amount_requested_cents']
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
END $$;

ROLLBACK;
