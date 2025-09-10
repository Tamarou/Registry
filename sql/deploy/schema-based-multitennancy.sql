-- Deploy registry:schema-based-multitennancy to pg
-- requires: tenant-on-boarding

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- This was entirely taken from stack overflow here:
-- https://stackoverflow.com/questions/2370614/copy-schema-and-create-new-schema-with-different-name-in-the-same-data-base/48732283#48732283

CREATE OR REPLACE FUNCTION copy_user(
    dest_schema text,
    user_id uuid,
    source_schema text DEFAULT 'registry'
) RETURNS void AS
$BODY$

BEGIN
-- Check that source_schema exists
  PERFORM nspname
  FROM pg_namespace
  WHERE nspname = quote_ident(source_schema);
  IF NOT FOUND
  THEN
    RAISE NOTICE 'source schema % does not exist!', source_schema;
    RETURN ;
  END IF;

-- Check that dest_schema exists
  PERFORM nspname
  FROM pg_namespace
  WHERE nspname = quote_ident(source_schema);
  IF NOT FOUND
  THEN
    RAISE NOTICE 'dest schema % does not exist!', source_schema;
    RETURN ;
  END IF;

  EXECUTE 'INSERT INTO '|| quote_ident(dest_schema) || '.users SELECT * FROM ' || quote_ident(source_schema) || '.users WHERE id = ' || quote_literal(user_id);
  
  -- Also copy user_profiles data
  EXECUTE 'INSERT INTO '|| quote_ident(dest_schema) || '.user_profiles SELECT * FROM ' || quote_ident(source_schema) || '.user_profiles WHERE user_id = ' || quote_literal(user_id);
END

$BODY$
LANGUAGE plpgsql VOLATILE
COST 100;

CREATE OR REPLACE FUNCTION copy_workflow(
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
    WHERE nspname = quote_ident(source_schema);
    IF NOT FOUND THEN
        RAISE NOTICE 'Source schema % does not exist!', source_schema;
        RETURN;
    END IF;

    -- Check that dest_schema exists
    PERFORM nspname
    FROM pg_namespace
    WHERE nspname = quote_ident(dest_schema);
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
    EXECUTE 'INSERT INTO ' || quote_ident(dest_schema) || '.workflows (name, slug, description, first_step)
              SELECT name, slug, description, first_step
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

CREATE OR REPLACE FUNCTION clone_schema(
    dest_schema text,
    source_schema text DEFAULT 'registry',
    show_details boolean DEFAULT false,  -- be verbose
    include_recs boolean DEFAULT false   -- include data
) RETURNS void AS
$BODY$

--  This function will clone all sequences, tables, data, views & functions from any existing schema to a new one
-- SAMPLE CALL:
-- SELECT clone_schema('public', 'new_schema');
-- SELECT clone_schema('public', 'new_schema', TRUE);
-- SELECT clone_schema('public', 'new_schema', TRUE, TRUE);

DECLARE
  src_oid          oid;
  tbl_oid          oid;
  func_oid         oid;
  object           text;
  buffer           text;
  srctbl           text;
  default_         text;
  column_          text;
  qry              text;
  xrec             record;
  dest_qry         text;
  v_def            text;
  seqval           bigint;
  sq_last_value    bigint;
  sq_max_value     bigint;
  sq_start_value   bigint;
  sq_increment_by  bigint;
  sq_min_value     bigint;
  sq_cache_value   bigint;
  sq_log_cnt       bigint;
  sq_is_called     boolean;
  sq_is_cycled     boolean;
  sq_cycled        char(10);
  rec              record;
  source_schema_dot text = source_schema || '.';
  dest_schema_dot text = dest_schema || '.';

BEGIN

  -- Check that source_schema exists
  SELECT oid INTO src_oid
  FROM pg_namespace
  WHERE nspname = quote_ident(source_schema);
  IF NOT FOUND
  THEN
    RAISE NOTICE 'source schema % does not exist!', source_schema;
    RETURN ;
  END IF;

  -- Check that dest_schema does not yet exist
  PERFORM nspname
  FROM pg_namespace
  WHERE nspname = quote_ident(dest_schema);
  IF FOUND
  THEN
    RAISE NOTICE 'dest schema % already exists!', dest_schema;
    RETURN ;
  END IF;

  EXECUTE 'CREATE SCHEMA ' || quote_ident(dest_schema) ;

  -- Defaults search_path to destination schema
  PERFORM set_config('search_path', dest_schema, true);

  -- Create sequences
  -- TODO: Find a way to make this sequence's owner is the correct table.
  FOR object IN
  SELECT sequence_name::text
  FROM information_schema.sequences
  WHERE sequence_schema = quote_ident(source_schema)
  LOOP
    EXECUTE 'CREATE SEQUENCE ' || quote_ident(dest_schema) || '.' || quote_ident(object);
    srctbl := quote_ident(source_schema) || '.' || quote_ident(object);

    EXECUTE 'SELECT last_value, max_value, start_value, increment_by, min_value, cache_value, log_cnt, is_cycled, is_called
              FROM ' || quote_ident(source_schema) || '.' || quote_ident(object) || ';'
    INTO sq_last_value, sq_max_value, sq_start_value, sq_increment_by, sq_min_value, sq_cache_value, sq_log_cnt, sq_is_cycled, sq_is_called ;

    IF sq_is_cycled
    THEN
      sq_cycled := 'CYCLE';
    ELSE
      sq_cycled := 'NO CYCLE';
    END IF;

    EXECUTE 'ALTER SEQUENCE '   || quote_ident(dest_schema) || '.' || quote_ident(object)
            || ' INCREMENT BY ' || sq_increment_by
            || ' MINVALUE '     || sq_min_value
            || ' MAXVALUE '     || sq_max_value
            || ' START WITH '   || sq_start_value
            || ' RESTART '      || sq_min_value
            || ' CACHE '        || sq_cache_value
            || sq_cycled || ' ;' ;

    buffer := quote_ident(dest_schema) || '.' || quote_ident(object);
    IF include_recs
    THEN
      EXECUTE 'SELECT setval( ''' || buffer || ''', ' || sq_last_value || ', ' || sq_is_called || ');' ;
    ELSE
      EXECUTE 'SELECT setval( ''' || buffer || ''', ' || sq_start_value || ', ' || sq_is_called || ');' ;
    END IF;
  END LOOP;

  -- Create tables
  FOR object IN
  SELECT TABLE_NAME::text
  FROM information_schema.tables
  WHERE table_schema = quote_ident(source_schema)
        AND table_type = 'BASE TABLE'

  LOOP
    buffer := dest_schema || '.' || quote_ident(object);
    EXECUTE 'CREATE TABLE ' || buffer || ' (LIKE ' || quote_ident(source_schema) || '.' || quote_ident(object) || ' INCLUDING ALL)';

    FOR column_, default_ IN
    SELECT column_name::text,
      REPLACE(column_default::text, source_schema, dest_schema)
    FROM information_schema.COLUMNS
    WHERE table_schema = dest_schema
          AND TABLE_NAME = object
          AND column_default LIKE 'nextval(%' || quote_ident(source_schema) || '%::regclass)'
    LOOP
      EXECUTE 'ALTER TABLE ' || buffer || ' ALTER COLUMN ' || column_ || ' SET DEFAULT ' || default_;
    END LOOP;


  END LOOP;

  --  add FK constraint
  FOR xrec IN
  SELECT ct.conname as fk_name, rn.relname as tb_name,  'ALTER TABLE ' || quote_ident(dest_schema) || '.' || quote_ident(rn.relname)
         || ' ADD CONSTRAINT ' || quote_ident(ct.conname) || ' ' || replace(pg_get_constraintdef(ct.oid), source_schema_dot, '') || ';' as qry
  FROM pg_constraint ct
    JOIN pg_class rn ON rn.oid = ct.conrelid
  WHERE connamespace = src_oid
        AND rn.relkind = 'r'
        AND ct.contype = 'f'

  LOOP
    --RAISE NOTICE 'DEF: %', xrec.qry;
    EXECUTE xrec.qry;
  END LOOP;

  -- Create functions
  FOR xrec IN
  SELECT proname as func_name, oid as func_oid
  FROM pg_proc
  WHERE pronamespace = src_oid

  LOOP
    SELECT pg_get_functiondef(xrec.func_oid) INTO qry;
    SELECT replace(qry, source_schema_dot, '') INTO dest_qry;
    EXECUTE dest_qry;
  END LOOP;

  -- add Table Triggers
  FOR rec IN
  SELECT
    trg.tgname AS trigger_name,
    tbl.relname AS trigger_table,

    CASE
    WHEN trg.tgenabled='O' THEN 'ENABLED'
    ELSE 'DISABLED'
    END AS status,
    CASE trg.tgtype::integer & 1
    WHEN 1 THEN 'ROW'::text
    ELSE 'STATEMENT'::text
    END AS trigger_level,
    CASE trg.tgtype::integer & 66
    WHEN 2 THEN 'BEFORE'
    WHEN 64 THEN 'INSTEAD OF'
    ELSE 'AFTER'
    END AS action_timing,
    CASE trg.tgtype::integer & cast(60 AS int2)
    WHEN 16 THEN 'UPDATE'
    WHEN 8 THEN 'DELETE'
    WHEN 4 THEN 'INSERT'
    WHEN 20 THEN 'INSERT OR UPDATE'
    WHEN 28 THEN 'INSERT OR UPDATE OR DELETE'
    WHEN 24 THEN 'UPDATE OR DELETE'
    WHEN 12 THEN 'INSERT OR DELETE'
    WHEN 32 THEN 'TRUNCATE'
    END AS trigger_event,
    'EXECUTE PROCEDURE ' ||  (SELECT nspname FROM pg_namespace where oid = pc.pronamespace )
    || '.' || proname || '('
    || regexp_replace(replace(trim(trailing '\000' from encode(tgargs,'escape')), '\000',','),'{(.+)}','''{\1}''','g')
    || ')' as action_statement

  FROM pg_trigger trg
    JOIN pg_class tbl on trg.tgrelid = tbl.oid
    JOIN pg_proc pc ON pc.oid = trg.tgfoid
  WHERE trg.tgname not like 'RI_ConstraintTrigger%'
        AND trg.tgname not like 'pg_sync_pg%'
        AND tbl.relnamespace = (SELECT oid FROM pg_namespace where nspname = quote_ident(source_schema) )

  LOOP
    buffer := dest_schema || '.' || quote_ident(rec.trigger_table);
    EXECUTE 'CREATE TRIGGER ' || rec.trigger_name || ' ' || rec.action_timing
            || ' ' || rec.trigger_event || ' ON ' || buffer || ' FOR EACH '
            || rec.trigger_level || ' ' || replace(rec.action_statement, source_schema_dot, '');

  END LOOP;

  -- Create views
  FOR object IN
  SELECT table_name::text,
    view_definition
  FROM information_schema.views
  WHERE table_schema = quote_ident(source_schema)

  LOOP
    buffer := dest_schema || '.' || quote_ident(object);
    SELECT replace(view_definition, source_schema_dot, '') INTO v_def
    FROM information_schema.views
    WHERE table_schema = quote_ident(source_schema)
          AND table_name = quote_ident(object);
    EXECUTE 'CREATE OR REPLACE VIEW ' || buffer || ' AS ' || v_def || ';' ;

  END LOOP;

  RETURN;

END;

$BODY$
LANGUAGE plpgsql VOLATILE
COST 100;

COMMIT;
