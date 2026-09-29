-- ABOUTME: Verify no schema still carries the instalment columns the configuration replaced.
-- ABOUTME: Checked across tenants, because clone_schema gives every tenant a copy of the table.

-- Verify registry:instalments-declared-in-configuration on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.pricing_plans', s)) IS NULL;

        IF EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = s AND table_name = 'pricing_plans'
               AND column_name IN ('installments_allowed', 'installment_count')
        ) THEN
            RAISE EXCEPTION
                'pricing_plans still carries the instalment columns in schema %', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
