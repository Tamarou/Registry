-- ABOUTME: Drop offer versions' price, units, payment plans, policies and conditions everywhere.
-- ABOUTME: Nothing has been sold on them yet, so no data is carried anywhere.

-- Revert registry:priceops-offer-policies from pg

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
        EXECUTE format($f$
            ALTER TABLE %I.offer_versions
                DROP COLUMN IF EXISTS price_cents,
                DROP COLUMN IF EXISTS units_per_acceptance,
                DROP COLUMN IF EXISTS per_booking_cap
        $f$, s);
    END LOOP;
END $$;

COMMIT;
