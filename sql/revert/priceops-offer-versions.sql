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
        EXECUTE format('DROP TABLE IF EXISTS %I.resources', s);
    END LOOP;
END $$;

COMMIT;
