-- ABOUTME: Who may run a workflow becomes data on its row: a list of roles, or the public mark.
-- ABOUTME: Added in registry and every tenant schema; nothing reads it yet, the gate still reads Registry.pm's map.

-- Deploy registry:workflow-roles-data to pg
-- requires: drop-tenant-billing-columns

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
        -- NULL roles and public false is "no entry": the next step's gate refuses it.
        EXECUTE format('ALTER TABLE %I.workflows ADD COLUMN IF NOT EXISTS roles text[]', s);
        EXECUTE format('ALTER TABLE %I.workflows ADD COLUMN IF NOT EXISTS public boolean NOT NULL DEFAULT false', s);
    END LOOP;
END $$;

-- copy_workflow carries who may run the workflow into the tenant's copy;
-- otherwise unchanged from fix-clone-schema-identifier-quoting.
CREATE OR REPLACE FUNCTION registry.copy_workflow(
    dest_schema text,
    workflow_id uuid,
    source_schema text DEFAULT 'registry'
) RETURNS void AS
$BODY$
DECLARE
    new_workflow_id uuid;
    old_template_id uuid;
    new_template_id uuid;
    old_step_id uuid;
    new_step_id uuid;
    v_first_step text;
BEGIN
    -- Check that source_schema exists
    PERFORM nspname
    FROM pg_namespace
    WHERE nspname = source_schema;
    IF NOT FOUND THEN
        RAISE NOTICE 'Source schema % does not exist!', source_schema;
        RETURN;
    END IF;

    -- Check that dest_schema exists.  Compare against the plain nspname value,
    -- not quote_ident(dest_schema): nspname stores the unquoted schema name
    -- ('user', not '"user"'), so wrapping in quote_ident causes the lookup to
    -- fail for reserved-word schema names, making the function silently return.
    PERFORM nspname
    FROM pg_namespace
    WHERE nspname = dest_schema;
    IF NOT FOUND THEN
        RAISE NOTICE 'Destination schema % does not exist!', dest_schema;
        RETURN;
    END IF;

    -- Get the workflow's first_step value
    EXECUTE 'SELECT first_step FROM ' || quote_ident(source_schema) || '.workflows WHERE id = ' || quote_literal(workflow_id)
    INTO v_first_step;

    IF v_first_step IS NULL THEN
        RAISE NOTICE 'Workflow % has no first_step defined', workflow_id;
    END IF;

    -- Copy the workflow
    EXECUTE 'INSERT INTO ' || quote_ident(dest_schema) || '.workflows (name, slug, description, first_step, roles, public)
              SELECT name, slug, description, first_step, roles, public
              FROM ' || quote_ident(source_schema) || '.workflows
              WHERE id = ' || quote_literal(workflow_id) || ' RETURNING id'
    INTO new_workflow_id;

    IF new_workflow_id IS NULL THEN
        RAISE NOTICE 'Workflow with ID % does not exist in source schema!', workflow_id;
        RETURN;
    END IF;

    -- Create a temporary table for mapping old to new step IDs
    CREATE TEMP TABLE old_to_new_step_ids (
        old_step_id uuid,
        new_step_id uuid
    );

    -- Track step slugs for verification
    CREATE TEMP TABLE step_slugs (
        step_id uuid,
        slug text
    );

    -- First, copy all workflow steps regardless of templates
    FOR old_step_id IN
        EXECUTE 'SELECT id FROM ' || quote_ident(source_schema) || '.workflow_steps
                 WHERE workflow_id = ' || quote_literal(workflow_id)
    LOOP
        -- Get the step slug
        DECLARE
            v_step_slug text;
        BEGIN
            EXECUTE 'SELECT slug FROM ' || quote_ident(source_schema) || '.workflow_steps WHERE id = ' || quote_literal(old_step_id)
            INTO v_step_slug;

            -- Copy the step with a NULL template_id initially
            EXECUTE 'INSERT INTO ' || quote_ident(dest_schema) || '.workflow_steps
                     (workflow_id, slug, description, template_id, metadata, class, outcome_definition_id)
                     SELECT ' || quote_literal(new_workflow_id) || ', slug, description, NULL, metadata, class, outcome_definition_id
                     FROM ' || quote_ident(source_schema) || '.workflow_steps
                     WHERE id = ' || quote_literal(old_step_id) || ' RETURNING id'
            INTO new_step_id;

            -- Store mapping and slug information
            INSERT INTO old_to_new_step_ids (old_step_id, new_step_id)
            VALUES (old_step_id, new_step_id);

            INSERT INTO step_slugs (step_id, slug)
            VALUES (new_step_id, v_step_slug);
        END;
    END LOOP;

    -- Now handle templates
    FOR old_template_id IN
        EXECUTE 'SELECT DISTINCT template_id
                FROM ' || quote_ident(source_schema) || '.workflow_steps
                WHERE workflow_id = ' || quote_literal(workflow_id) || '
                AND template_id IS NOT NULL'
    LOOP
        -- Copy the template
        EXECUTE 'INSERT INTO ' || quote_ident(dest_schema) || '.templates
                 (name, slug, content, metadata)
                 SELECT name, slug, content, metadata
                 FROM ' || quote_ident(source_schema) || '.templates
                 WHERE id = ' || quote_literal(old_template_id) || ' RETURNING id'
        INTO new_template_id;

        -- Update the corresponding steps with the new template_id
        EXECUTE 'UPDATE ' || quote_ident(dest_schema) || '.workflow_steps new_steps
                 SET template_id = ' || quote_literal(new_template_id) || '
                 WHERE new_steps.id IN (
                     SELECT new_step_id
                     FROM old_to_new_step_ids mapping
                     JOIN ' || quote_ident(source_schema) || '.workflow_steps old_steps
                          ON old_steps.id = mapping.old_step_id
                     WHERE old_steps.template_id = ' || quote_literal(old_template_id) || '
                 )';
    END LOOP;

    -- Update the depends_on relationships
    FOR old_step_id IN
        EXECUTE 'SELECT id FROM ' || quote_ident(source_schema) || '.workflow_steps
                 WHERE workflow_id = ' || quote_literal(workflow_id) || '
                 AND depends_on IS NOT NULL'
    LOOP
        EXECUTE 'UPDATE ' || quote_ident(dest_schema) || '.workflow_steps new_steps
                 SET depends_on = (
                     SELECT new_step_id
                     FROM old_to_new_step_ids
                     WHERE old_step_id = (
                         SELECT depends_on
                         FROM ' || quote_ident(source_schema) || '.workflow_steps
                         WHERE id = ' || quote_literal(old_step_id) || '
                     )
                 )
                 WHERE new_steps.id = (
                     SELECT new_step_id
                     FROM old_to_new_step_ids
                     WHERE old_step_id = ' || quote_literal(old_step_id) || '
                 )';
    END LOOP;

    -- Verify first_step exists and has a matching step
    DECLARE
        v_step_count integer;
    BEGIN
        IF v_first_step IS NOT NULL THEN
            EXECUTE 'SELECT COUNT(*) FROM ' || quote_ident(dest_schema) ||
                    '.workflow_steps WHERE workflow_id = $1 AND slug = $2'
            INTO v_step_count
            USING new_workflow_id, v_first_step;

            IF v_step_count = 0 THEN
                RAISE WARNING 'Workflow %: first_step slug "% has no matching step in destination schema', new_workflow_id, v_first_step;

                -- Create a default landing step if needed
                IF v_first_step = 'landing' THEN
                    EXECUTE 'INSERT INTO ' || quote_ident(dest_schema) || '.workflow_steps ' ||
                            '(workflow_id, slug, description) ' ||
                            'VALUES ($1, $2, $3) RETURNING id'
                    INTO new_step_id
                    USING new_workflow_id, 'landing', 'Default landing page';

                    RAISE NOTICE 'Created default landing step for workflow %', new_workflow_id;
                END IF;
            ELSE
                RAISE NOTICE 'Verified first_step % exists for workflow %', v_first_step, new_workflow_id;
            END IF;
        END IF;
    END;

    -- Clean up
    DROP TABLE old_to_new_step_ids;
    DROP TABLE step_slugs;

    RAISE NOTICE 'Workflow % copied to % schema with ID %', workflow_id, dest_schema, new_workflow_id;
END;
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100;


COMMIT;
