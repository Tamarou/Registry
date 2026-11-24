-- ABOUTME: Verify every schema's resources can be bound to an occurrence.
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
    END LOOP;
END $$;

ROLLBACK;
