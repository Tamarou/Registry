-- Deploy registry:workflow-step-label to pg
-- requires: send-cap-setting

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- What a person walking through a workflow reads for this step.
--
-- `description` already existed and is not this. It is a developer note, and it
-- reads like one: the shipped workflow YAML carries "Tenant profile page",
-- "Tenant users page", "New Tenant landing page". Its other reader is the CLI
-- listing in Registry::Command::workflow, which prints it beside the slug for
-- somebody debugging a workflow definition. Those are the right words for that
-- audience and the wrong ones for a parent or a tenant's owner, so this is a
-- second column rather than a rewrite of the first.
--
-- NULLABLE on purpose. NULL means "no label written yet", and the progress
-- indicator falls back to `description` and then to a title-cased slug, so a
-- workflow that never sets one still renders something sensible. An empty
-- string would be a label that says nothing, which is different.
ALTER TABLE workflow_steps
  ADD COLUMN IF NOT EXISTS label text;

COMMENT ON COLUMN workflow_steps.label IS
  'User-facing name for this step, shown in the workflow progress indicator. '
  'NULL means none written: callers fall back to description, then to the slug. '
  'Distinct from description, which is a developer note shown in the CLI.';

-- Propagate to tenant schemas: clone_schema copies workflow_steps into every
-- tenant schema, so each carries its own copy of this table.
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- A tenant row whose schema was never built, or was built without this
        -- table. `registry-platform` is exactly that in production -- the shape
        -- #265 and the fleet screen are about -- and iterating it blind is how
        -- an earlier migration failed its first deploy. The same guard every
        -- recent migration uses (#176 wants it standardised).
        CONTINUE WHEN to_regclass(format('%I.workflow_steps', s)) IS NULL;

        EXECUTE format('ALTER TABLE %I.workflow_steps
            ADD COLUMN IF NOT EXISTS label text;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
