-- ABOUTME: Narrows every stored template-editor workflow to admin, as its YAML now declares, in registry and every tenant schema.
-- ABOUTME: Workflow::from_yaml returns an existing workflow untouched, so the YAML alone changes no row already deployed.

-- Deploy registry:template-editor-admin-only to pg
-- requires: registry-run-right-at-import

BEGIN;

SET client_min_messages = 'warning';

-- Saved template text is .ep, run as Perl on the server (01a21471-adf9). The
-- TemplateEditor step refuses every writer but the platform operator's admins;
-- this keeps the stored rows agreeing with the YAML's roles: [admin].
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
        EXECUTE format($sql$UPDATE %I.workflows SET roles = ARRAY['admin'] WHERE slug = 'template-editor'$sql$, s);
    END LOOP;
END $$;

COMMIT;
