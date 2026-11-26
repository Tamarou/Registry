-- ABOUTME: Verify no stored registry template-editor workflow lets anyone but admin run it.
-- ABOUTME: Passes when the workflow is absent (pre-import).

-- Verify registry:template-editor-admin-only on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.workflows
                WHERE slug = 'template-editor' AND roles IS DISTINCT FROM ARRAY['admin']) THEN
        RAISE EXCEPTION 'template-editor is stored with roles other than [admin]';
    END IF;
END $$;

ROLLBACK;
