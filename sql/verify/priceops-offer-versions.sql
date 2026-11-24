-- ABOUTME: Verify registry and every tenant schema carry the PriceOps resource and offer tables.
-- ABOUTME: Checked per schema, because a tenant's offers live in its own schema.

-- Verify registry:priceops-offer-versions on pg

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
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        IF to_regclass(format('%I.resources', s)) IS NULL THEN
            RAISE EXCEPTION 'resources missing in schema %', s;
        END IF;
        IF to_regclass(format('%I.offers', s)) IS NULL THEN
            RAISE EXCEPTION 'offers missing in schema %', s;
        END IF;
        IF to_regclass(format('%I.offer_versions', s)) IS NULL THEN
            RAISE EXCEPTION 'offer_versions missing in schema %', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
