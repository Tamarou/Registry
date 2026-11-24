-- ABOUTME: An offer version's price, units, payment plans, policies and conditions, as declared data.
-- ABOUTME: Built in registry and every tenant schema; published versions' plans are immutable too.

-- Deploy registry:priceops-offer-policies to pg
-- requires: priceops-offer-versions

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
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        -- Columns on the version row are covered by offer_versions_immutable
        -- with no change to it. Nothing has been sold, so no row needs a value.
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_versions
                ADD COLUMN price_cents integer NOT NULL
                    CONSTRAINT offer_versions_price_cents_check CHECK (price_cents >= 0),
                ADD COLUMN units_per_acceptance integer NOT NULL
                    CONSTRAINT offer_versions_units_per_acceptance_check CHECK (units_per_acceptance > 0),
                ADD COLUMN per_booking_cap integer NOT NULL
                    CONSTRAINT offer_versions_per_booking_cap_check CHECK (per_booking_cap > 0)
        $f$, s);
    END LOOP;
END $$;

COMMIT;
