-- ABOUTME: Unbind resources from occurrences and drop class offers in registry and every tenant schema.
-- ABOUTME: Nothing has been sold on them yet; a class offer version left behind makes this fail, not vanish.

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
        -- Dropping a column drops its key, foreign key and checks.
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_versions
                DROP COLUMN class_project_id,
                ALTER COLUMN resource_id SET NOT NULL
        $f$, s);
        EXECUTE format('ALTER TABLE %I.projects DROP COLUMN seats_per_occurrence', s);
        EXECUTE format('ALTER TABLE %I.resources DROP COLUMN event_id', s);
    END LOOP;
END $$;

COMMIT;
