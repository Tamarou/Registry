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

        -- The plans a customer chooses between. The id is the publisher's,
        -- unique within the version, so an entitlement can record which plan
        -- it was accepted under. A fraction is held to 4 decimal places by
        -- refusal, never rounding. A new kind is a new CHECK value plus its
        -- own columns, never a reinterpretation of these.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.offer_version_payment_plans (
                offer_version_id uuid NOT NULL
                    REFERENCES %1$I.offer_versions (id) ON DELETE CASCADE,
                id       text NOT NULL CHECK (id <> ''),
                kind     text NOT NULL CHECK (kind IN ('one_time', 'percentage_of_sales')),
                fraction numeric
                    CONSTRAINT offer_version_payment_plans_fraction_check
                    CHECK (fraction >= 0 AND fraction <= 1 AND scale(fraction) <= 4),
                PRIMARY KEY (offer_version_id, id),
                CONSTRAINT offer_version_payment_plans_fraction_matches_kind
                    CHECK ((kind = 'percentage_of_sales') = (fraction IS NOT NULL))
            )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
