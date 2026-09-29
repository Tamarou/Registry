-- ABOUTME: Restore the instalment columns, empty.
-- ABOUTME: Any schedule declared in pricing_configuration stays there; this cannot translate it back.

-- Revert registry:instalments-declared-in-configuration from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- The columns come back with their original defaults and no data. A plan whose
-- schedule was declared in pricing_configuration keeps it there -- the JSON is
-- untouched by this revert -- so reverting loses the offer rather than the
-- terms, and re-deploying restores it.
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
        EXECUTE format(
            'ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS installments_allowed boolean DEFAULT false', s );
        EXECUTE format(
            'ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS installment_count integer', s );
    END LOOP;
END $$;

COMMIT;
