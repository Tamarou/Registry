-- ABOUTME: Drops the payments offer version stamp and its trigger from registry and every tenant schema.
-- ABOUTME: The stamp's values are lost; nothing else reads them.

-- Revert registry:payments-offer-version-stamp from pg

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
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;
        EXECUTE format('DROP TRIGGER IF EXISTS payments_offer_version_stamp ON %I.payments', s);
        EXECUTE format('ALTER TABLE %I.payments DROP COLUMN IF EXISTS offer_version_id', s);
    END LOOP;
END $$;

DROP FUNCTION IF EXISTS registry.payment_offer_version_stamp();

COMMIT;
