-- ABOUTME: Drops the missed_payment kind CHECK from offer versions in registry and every tenant schema.
-- ABOUTME: Stored conditions are left as they are; the singular sibling shape is not restored by any row change.

-- Revert registry:priceops-session-vocabulary from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.offer_versions', s)) IS NULL;
        EXECUTE format('ALTER TABLE %I.offer_versions DROP CONSTRAINT IF EXISTS offer_versions_missed_payment_kind_check', s);
    END LOOP;
END $$;

COMMIT;
