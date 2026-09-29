-- ABOUTME: Verify every schema holding payments can express an instalment of a set.
-- ABOUTME: Includes the pairing constraint, because a sequence without a count renders nothing.

-- Verify registry:payments-carry-instalments on pg

BEGIN;

DO $$
DECLARE
    s name;
    c text;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        FOREACH c IN ARRAY ARRAY['instalment_seq','instalment_count','due_date','stripe_schedule_id']
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = 'payments' AND column_name = c
            ) THEN
                RAISE EXCEPTION 'payments.% missing in schema %', c, s;
            END IF;
        END LOOP;

        -- By name here rather than by shape: this is a named CHECK constraint the
        -- migration adds explicitly, and clone_schema's LIKE INCLUDING ALL copies
        -- CHECK constraints with their names -- unlike indexes, which it lets
        -- Postgres rename (see pricing-plan-versions).
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint co
              JOIN pg_class cl ON cl.oid = co.conrelid
              JOIN pg_namespace n ON n.oid = cl.relnamespace
             WHERE n.nspname = s AND cl.relname = 'payments'
               AND co.conname = 'payments_instalment_pair'
        ) THEN
            RAISE EXCEPTION 'payments_instalment_pair constraint missing in schema %', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
