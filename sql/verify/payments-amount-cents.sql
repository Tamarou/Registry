-- ABOUTME: Verify payments and payment_items carry integer cents, in every schema.
-- ABOUTME: A tenant left on the dollars column would charge in the wrong units.

-- Verify registry:payments-amount-cents on pg

BEGIN;

DO $$
DECLARE
    s name;
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['payments', 'payment_items'] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'registry' AND table_name = t
               AND column_name = 'amount_cents' AND data_type = 'integer'
        ) THEN
            RAISE EXCEPTION 'registry.% has no integer amount_cents column', t;
        END IF;

        IF EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'registry' AND table_name = t
               AND column_name = 'amount'
        ) THEN
            RAISE EXCEPTION 'registry.% still has the dollars column', t;
        END IF;
    END LOOP;

    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        FOREACH t IN ARRAY ARRAY['payments', 'payment_items'] LOOP
            IF NOT EXISTS (
                SELECT 1 FROM information_schema.columns
                 WHERE table_schema = s AND table_name = t
                   AND column_name = 'amount_cents'
            ) THEN
                RAISE EXCEPTION 'tenant schema %.% was not converted', s, t;
            END IF;
        END LOOP;
    END LOOP;
END $$;

ROLLBACK;
