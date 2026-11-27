-- ABOUTME: Verify every schema's payment plans carry count, cadence and surcharge_pct, and its offer versions
-- ABOUTME: have the trigger refusing to publish instalments without a missed_payment policy.

-- Verify registry:instalment-payment-plans on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.offer_version_payment_plans', s)) IS NULL;
        EXECUTE format('SELECT count, cadence, surcharge_pct FROM %I.offer_version_payment_plans WHERE false', s);
        IF NOT EXISTS (SELECT 1 FROM pg_trigger
                        WHERE tgname = 'offer_versions_instalments_need_missed_payment'
                          AND tgrelid = format('%I.offer_versions', s)::regclass) THEN
            RAISE EXCEPTION 'schema % lacks offer_versions_instalments_need_missed_payment', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
