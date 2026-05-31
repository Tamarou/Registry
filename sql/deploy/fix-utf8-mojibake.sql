-- Deploy fix-utf8-mojibake
-- Delete DB templates so the app reimports from the fixed filesystem versions on startup.

BEGIN;

SET search_path TO registry, public;

-- Only delete templates that are NOT referenced by workflow_steps. Deleting a
-- referenced row violates workflow_steps_template_id_fkey. The referenced
-- templates are refreshed in place by the `template import` step that runs on
-- startup (upsert by name), so they still pick up the fixed filesystem content.
DELETE FROM templates
WHERE name != 'tenant-storefront/program-listing'
  AND id NOT IN (
      SELECT template_id FROM workflow_steps WHERE template_id IS NOT NULL
  );

COMMIT;
