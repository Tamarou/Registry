-- ABOUTME: Verify every schema's holds carry lifetime.
-- ABOUTME: Checked per schema, because a tenant's holds live in its own schema.

-- Verify registry:holds-lifetime on pg

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
        CONTINUE WHEN to_regclass(format('%I.holds', s)) IS NULL;
        EXECUTE format('SELECT lifetime FROM %I.holds WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
