-- ABOUTME: Restores admin and staff to every stored template-editor workflow, as the reverted YAML declares.
-- ABOUTME: Registry and every tenant schema, mirroring the deploy.

-- Revert registry:template-editor-admin-only from pg

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
        CONTINUE WHEN to_regclass(format('%I.workflows', s)) IS NULL;
        EXECUTE format($sql$UPDATE %I.workflows SET roles = ARRAY['admin','staff'] WHERE slug = 'template-editor'$sql$, s);
    END LOOP;
END $$;

COMMIT;
