-- Verify registry:workflow-step-label on pg

BEGIN;

SET search_path TO registry, public;

-- The column exists, and is nullable: the progress indicator falls back to
-- description when no label is written, so NOT NULL would be a lie about every
-- step that has not been given one.
DO
$$
DECLARE
    is_nullable text;
BEGIN
    SELECT c.is_nullable INTO is_nullable
      FROM information_schema.columns c
     WHERE c.table_schema = 'registry'
       AND c.table_name   = 'workflow_steps'
       AND c.column_name  = 'label';

    IF is_nullable IS NULL THEN
        RAISE EXCEPTION 'registry.workflow_steps.label is missing';
    END IF;

    IF is_nullable <> 'YES' THEN
        RAISE EXCEPTION 'registry.workflow_steps.label must stay nullable, is %', is_nullable;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- And every tenant schema that has the table has the column, since clone_schema
-- copies this table per tenant.
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regclass(format('%I.workflow_steps', s)) IS NULL;

        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
             WHERE table_schema = s AND table_name = 'workflow_steps'
               AND column_name = 'label'
        ) THEN
            RAISE EXCEPTION '%.workflow_steps.label is missing', s;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;
