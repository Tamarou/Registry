-- ABOUTME: Unbind resources from occurrences in registry and every tenant schema.
-- ABOUTME: Nothing has been sold on them yet, so no data is carried anywhere.

-- Revert registry:priceops-occurrence-resources from pg

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
        CONTINUE WHEN to_regclass(format('%I.resources', s)) IS NULL;
        -- Dropping the column drops its key, foreign key and check.
        EXECUTE format('ALTER TABLE %I.resources DROP COLUMN event_id', s);
    END LOOP;
END $$;

COMMIT;
