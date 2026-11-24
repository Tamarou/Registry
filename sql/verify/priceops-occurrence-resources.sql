-- ABOUTME: Verify every schema binds resources to occurrences and offer versions to a class.
-- ABOUTME: Checked per schema, because a tenant's resources live in its own schema.

-- Verify registry:priceops-occurrence-resources on pg

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
        CONTINUE WHEN to_regclass(format('%I.resources', s)) IS NULL;
        EXECUTE format('SELECT event_id FROM %I.resources WHERE false', s);
        EXECUTE format('SELECT seats_per_occurrence FROM %I.projects WHERE false', s);
        EXECUTE format('SELECT class_project_id FROM %I.offer_versions WHERE false', s);
        PERFORM 1 / count(*) FROM pg_constraint
          WHERE conname = 'entitlement_units_entitlement_id_resource_id_excl'
            AND conrelid = format('%I.entitlement_units', s)::regclass;
    END LOOP;
END $$;

ROLLBACK;
