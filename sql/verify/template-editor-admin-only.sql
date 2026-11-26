-- ABOUTME: Verify no stored template-editor workflow, in registry or any tenant schema, lets anyone but admin run it.
-- ABOUTME: Passes when the workflow is absent (pre-import); checks every schema deploy touched.

-- Verify registry:template-editor-admin-only on pg

BEGIN;

DO $$
DECLARE
    s     name;
    wider boolean;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.workflows', s)) IS NULL;
        EXECUTE format($sql$SELECT EXISTS (SELECT 1 FROM %I.workflows
                         WHERE slug = 'template-editor' AND roles IS DISTINCT FROM ARRAY['admin'])$sql$, s)
           INTO wider;
        IF wider THEN
            RAISE EXCEPTION 'template-editor in % is stored with roles other than [admin]', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
