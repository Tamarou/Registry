-- ABOUTME: Drop PriceOps resources, offers and offer versions from registry and every tenant.
-- ABOUTME: Nothing has been sold on them yet, so no data is carried anywhere.

-- Revert registry:priceops-offer-versions from pg

BEGIN;

SET client_min_messages = 'warning';

-- Every schema, not only registry and the tenant rows: clone_schema copies
-- these tables into any schema it builds.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I.offer_versions', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.offers', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.resources', s);
        -- clone_schema copies registry's functions too, so a tenant provisioned
        -- after deploy has its own copy of the trigger function.
        CONTINUE WHEN s = 'registry';
        EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_version_immutable()', s);
    END LOOP;
END $$;

-- Last, after every table whose trigger used it is gone.
DROP FUNCTION IF EXISTS registry.offer_version_immutable();

COMMIT;
