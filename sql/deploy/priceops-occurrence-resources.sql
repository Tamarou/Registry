-- ABOUTME: An occurrence (an events row) is its own finite resource, bound by a same-schema foreign key.
-- ABOUTME: Built in registry and every tenant schema; clone_schema gives new tenants the same.

-- Deploy registry:priceops-occurrence-resources to pg
-- requires: priceops-entitlement-lifecycle

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

        -- One occurrence has at most one resource, and it holds seats. Default
        -- constraint names, as clone_schema's LIKE ... INCLUDING ALL gives.
        EXECUTE format($f$
            ALTER TABLE %1$I.resources
                ADD COLUMN event_id uuid UNIQUE REFERENCES %1$I.events (id),
                ADD CONSTRAINT resources_occurrence_is_finite
                    CHECK (event_id IS NULL OR kind = 'finite')
        $f$, s);
    END LOOP;
END $$;

COMMIT;
