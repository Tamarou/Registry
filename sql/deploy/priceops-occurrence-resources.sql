-- ABOUTME: An occurrence (an events row) is its own finite resource; a class offer version covers its class's.
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

        -- The class record: a class's occurrences are its events, and new ones
        -- get this many seats unless the occurrence says otherwise.
        EXECUTE format($f$
            ALTER TABLE %1$I.projects
                ADD COLUMN seats_per_occurrence integer CHECK (seats_per_occurrence >= 0)
        $f$, s);

        -- A version buys one named resource, or is a class offer covering
        -- every occurrence-resource of its class, now and later: a rule over
        -- the key, not a stored list, so offer_version_immutable freezes it
        -- with the rest of a published version.
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_versions
                ALTER COLUMN resource_id DROP NOT NULL,
                ADD COLUMN class_project_id uuid REFERENCES %1$I.projects (id),
                ADD CONSTRAINT offer_versions_buys_resource_or_class
                    CHECK (num_nonnulls(resource_id, class_project_id) = 1)
        $f$, s);

        -- One entitlement holds units of one resource: seats in two
        -- occurrences are two entitlements. btree_gist (from
        -- priceops-entitlement-one-phase) gives uuid its = and <>.
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlement_units
                ADD EXCLUDE USING gist (entitlement_id WITH =, resource_id WITH <>)
        $f$, s);
    END LOOP;
END $$;

COMMIT;
