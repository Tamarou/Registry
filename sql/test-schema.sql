--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: registry; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA registry;


ALTER SCHEMA registry OWNER TO postgres;

--
-- Name: sqitch; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA sqitch;


ALTER SCHEMA sqitch OWNER TO postgres;

--
-- Name: SCHEMA sqitch; Type: COMMENT; Schema: -; Owner: postgres
--

COMMENT ON SCHEMA sqitch IS 'Sqitch database deployment metadata v1.1.';


--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: notification_channel; Type: TYPE; Schema: registry; Owner: postgres
--

CREATE TYPE registry.notification_channel AS ENUM (
    'email',
    'in_app',
    'sms'
);


ALTER TYPE registry.notification_channel OWNER TO postgres;

--
-- Name: notification_type; Type: TYPE; Schema: registry; Owner: postgres
--

CREATE TYPE registry.notification_type AS ENUM (
    'attendance_missing',
    'attendance_reminder',
    'general',
    'magic_link_login',
    'magic_link_invite',
    'email_verification',
    'passkey_registered',
    'passkey_removed',
    'message_announcement',
    'message_update',
    'message_emergency',
    'enrollment_confirmation',
    'waitlist_joined',
    'domain_verified',
    'domain_verification_failed',
    'waitlist_offer',
    'waitlist_expiration'
);


ALTER TYPE registry.notification_type OWNER TO postgres;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO postgres;

--
-- Name: clone_schema(text, text, boolean, boolean); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.clone_schema(dest_schema text, source_schema text DEFAULT 'registry'::text, show_details boolean DEFAULT false, include_recs boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $$

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

    -- Get sequence parameters for PostgreSQL 17 compatibility
    EXECUTE 'SELECT s.seqstart, s.seqmax, s.seqstart, s.seqincrement, s.seqmin, s.seqcache, 0 as log_cnt, s.seqcycle, false as is_called
              FROM pg_sequence s
              JOIN pg_class c ON s.seqrelid = c.oid
              WHERE c.relname = ' || quote_literal(object) || ' AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = ' || quote_literal(source_schema) || ');'
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
            || ' ' || sq_cycled || ' ;' ;

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
    buffer := quote_ident(dest_schema) || '.' || quote_ident(object);
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
    buffer := quote_ident(dest_schema) || '.' || quote_ident(rec.trigger_table);
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
    buffer := quote_ident(dest_schema) || '.' || quote_ident(object);
    SELECT replace(view_definition, source_schema_dot, '') INTO v_def
    FROM information_schema.views
    WHERE table_schema = quote_ident(source_schema)
          AND table_name = quote_ident(object);
    EXECUTE 'CREATE OR REPLACE VIEW ' || buffer || ' AS ' || v_def || ';' ;

  END LOOP;

  RETURN;

END;

$$;


ALTER FUNCTION registry.clone_schema(dest_schema text, source_schema text, show_details boolean, include_recs boolean) OWNER TO postgres;

--
-- Name: copy_user(text, uuid, text); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.copy_user(dest_schema text, user_id uuid, source_schema text DEFAULT 'registry'::text) RETURNS void
    LANGUAGE plpgsql
    AS $$

BEGIN
-- Check that source_schema exists
  PERFORM nspname
  FROM pg_namespace
  WHERE nspname = source_schema;
  IF NOT FOUND
  THEN
    RAISE NOTICE 'source schema % does not exist!', source_schema;
    RETURN ;
  END IF;

-- Check that dest_schema exists
  PERFORM nspname
  FROM pg_namespace
  WHERE nspname = dest_schema;
  IF NOT FOUND
  THEN
    RAISE NOTICE 'dest schema % does not exist!', dest_schema;
    RETURN ;
  END IF;

  EXECUTE 'INSERT INTO '|| quote_ident(dest_schema) || '.users SELECT * FROM ' || quote_ident(source_schema) || '.users WHERE id = ' || quote_literal(user_id);

  -- Also copy user_profiles data
  EXECUTE 'INSERT INTO '|| quote_ident(dest_schema) || '.user_profiles SELECT * FROM ' || quote_ident(source_schema) || '.user_profiles WHERE user_id = ' || quote_literal(user_id);
END

$$;


ALTER FUNCTION registry.copy_user(dest_schema text, user_id uuid, source_schema text) OWNER TO postgres;

--
-- Name: copy_workflow(text, uuid, text); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.copy_workflow(dest_schema text, workflow_id uuid, source_schema text DEFAULT 'registry'::text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
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
$_$;


ALTER FUNCTION registry.copy_workflow(dest_schema text, workflow_id uuid, source_schema text) OWNER TO postgres;

--
-- Name: entitlement_holder_is_offerer(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.entitlement_holder_is_offerer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_TABLE_SCHEMA = 'registry'
       AND NEW.holder_tenant_id IS DISTINCT FROM '00000000-0000-0000-0000-000000000000'
       AND EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = NEW.offer_version_id
                      AND conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RAISE EXCEPTION 'offer version % is the platform''s offer to itself (holder_is_offerer): '
                        'only the platform tenant may hold it', NEW.offer_version_id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.entitlement_holder_is_offerer() OWNER TO postgres;

--
-- Name: entitlement_one_platform_term(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.entitlement_one_platform_term() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_TABLE_SCHEMA <> 'registry' OR NEW.holder_tenant_id IS NULL OR NEW.state <> 'active'
       OR NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                        JOIN registry.resources r ON r.id = v.resource_id
                       WHERE v.id = NEW.offer_version_id AND r.name = 'payment processing')
    THEN
        RETURN NEW;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('platform_entitlement:' || NEW.holder_tenant_id, 0));
    IF EXISTS (SELECT 1 FROM registry.entitlements e
                 JOIN registry.offer_versions v ON v.id = e.offer_version_id
                 JOIN registry.resources r ON r.id = v.resource_id
                WHERE e.holder_tenant_id = NEW.holder_tenant_id AND e.id <> NEW.id
                  AND e.state = 'active' AND r.name = 'payment processing'
                  AND e.in_effect && NEW.in_effect)
    THEN
        RAISE EXCEPTION 'tenant % already holds an active platform entitlement to payment processing '
                        'over %: end it before another begins', NEW.holder_tenant_id, NEW.in_effect;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.entitlement_one_platform_term() OWNER TO postgres;

--
-- Name: entitlement_stamp(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.entitlement_stamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
    is_draft boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.offer_version_id, NEW.payment_plan_id, NEW.offer_id, NEW.plan_kind)
           IS DISTINCT FROM (OLD.offer_version_id, OLD.payment_plan_id, OLD.offer_id, OLD.plan_kind)
        THEN
            RAISE EXCEPTION
                'entitlement % keeps the stamp it was sold under: its offer, '
                'offer version, payment plan and its kind cannot change.', OLD.id;
        END IF;
        IF (NEW.payment_id, NEW.payment_share_cents)
           IS DISTINCT FROM (OLD.payment_id, OLD.payment_share_cents)
        THEN
            RAISE EXCEPTION
                'entitlement % keeps the payment that created it and its share: '
                'the payment link is set only at insert.', OLD.id;
        END IF;
        IF OLD.state <> 'active'
           AND (NEW.state, NEW.ended_at, NEW.ended_reason, NEW.in_effect)
               IS DISTINCT FROM (OLD.state, OLD.ended_at, OLD.ended_reason, OLD.in_effect)
        THEN
            RAISE EXCEPTION
                'entitlement % ended as % (%): an ended entitlement keeps its first ending.',
                OLD.id, OLD.state, OLD.ended_reason;
        END IF;
        RETURN NEW;
    END IF;
    EXECUTE format('SELECT published_at IS NULL, offer_id FROM %I.offer_versions WHERE id = $1',
                   TG_TABLE_SCHEMA) INTO is_draft, NEW.offer_id USING NEW.offer_version_id;
    -- No such plan leaves the kind NULL, which the plan foreign key refuses.
    EXECUTE format('SELECT kind FROM %I.offer_version_payment_plans
                     WHERE offer_version_id = $1 AND id = $2', TG_TABLE_SCHEMA)
       INTO NEW.plan_kind USING NEW.offer_version_id, NEW.payment_plan_id;
    IF is_draft THEN
        RAISE EXCEPTION 'offer version % is a draft: nothing is sold under it until it is published',
            NEW.offer_version_id;
    END IF;
    RETURN NEW;
END;
$_$;


ALTER FUNCTION registry.entitlement_stamp() OWNER TO postgres;

--
-- Name: get_next_waitlist_position(uuid); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.get_next_waitlist_position(p_session_id uuid) RETURNS integer
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN COALESCE(
        (SELECT MAX(position) + 1 FROM waitlist 
         WHERE session_id = p_session_id AND status = 'waiting'),
        1
    );
END;
$$;


ALTER FUNCTION registry.get_next_waitlist_position(p_session_id uuid) OWNER TO postgres;

--
-- Name: offer_version_immutable(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.offer_version_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.published_at IS NULL THEN
        RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'offer_versions rows are append-only once published (offer % version %): '
            'a published version cannot be deleted.',
            OLD.offer_id, OLD.version;
    END IF;
    IF ( to_jsonb(NEW) - 'superseded_at' ) IS DISTINCT FROM ( to_jsonb(OLD) - 'superseded_at' )
       OR ( OLD.superseded_at IS NOT NULL AND NEW.superseded_at IS DISTINCT FROM OLD.superseded_at )
    THEN
        RAISE EXCEPTION
            'offer_versions rows are immutable once published (offer % version %): '
            'publish a new version instead. Only superseded_at may change, and only once.',
            OLD.offer_id, OLD.version;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.offer_version_immutable() OWNER TO postgres;

--
-- Name: offer_version_payment_plan_immutable(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.offer_version_payment_plan_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
    old_version uuid;
    new_version uuid;
    v record;
BEGIN
    IF TG_OP <> 'INSERT' THEN old_version := OLD.offer_version_id; END IF;
    IF TG_OP <> 'DELETE' THEN new_version := NEW.offer_version_id; END IF;
    -- FOR SHARE, so a concurrent publish waits for this change, or this one
    -- sees it. It locks only rows returned, so a draft is filtered out below.
    FOR v IN EXECUTE format(
        'SELECT offer_id, version, published_at FROM %I.offer_versions
          WHERE id IN ($1, $2) FOR SHARE', TG_TABLE_SCHEMA)
        USING old_version, new_version
    LOOP
        CONTINUE WHEN v.published_at IS NULL;
        RAISE EXCEPTION
            'offer % version % is published: its payment plans cannot be '
            'added, changed or removed. Publish a new version instead.',
            v.offer_id, v.version;
    END LOOP;
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$_$;


ALTER FUNCTION registry.offer_version_payment_plan_immutable() OWNER TO postgres;

--
-- Name: offer_version_requires_payment_plan(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.offer_version_requires_payment_plan() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
    has_plan boolean;
BEGIN
    IF NEW.published_at IS NULL THEN RETURN NULL; END IF;
    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM %I.offer_version_payment_plans WHERE offer_version_id = $1)',
        TG_TABLE_SCHEMA) INTO has_plan USING NEW.id;
    IF NOT has_plan THEN
        RAISE EXCEPTION 'offer % version % has no payment plan and cannot be published',
            NEW.offer_id, NEW.version;
    END IF;
    RETURN NULL;
END;
$_$;


ALTER FUNCTION registry.offer_version_requires_payment_plan() OWNER TO postgres;

--
-- Name: offer_versions_keep_platform_offer(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.offer_versions_keep_platform_offer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_TABLE_SCHEMA <> 'registry'
       OR NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                        JOIN registry.resources r ON r.id = v.resource_id
                        JOIN registry.offer_version_payment_plans p
                          ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                       WHERE v.id = OLD.id AND r.name = 'payment processing'
                         AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RETURN NULL;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('platform_offer_to_tenants', 0));
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                     JOIN registry.resources r ON r.id = v.resource_id
                     JOIN registry.offer_version_payment_plans p
                       ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                    WHERE r.name = 'payment processing'
                      AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
                      AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RAISE EXCEPTION 'retiring offer version % leaves no current published platform offer to tenants: '
                        'signup could grant none. Publish one on payment processing with a '
                        'percentage-of-sales plan first', OLD.id;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION registry.offer_versions_keep_platform_offer() OWNER TO postgres;

--
-- Name: payment_offer_version_stamp(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.payment_offer_version_stamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.offer_version_id IS NOT NULL
       AND NEW.offer_version_id IS DISTINCT FROM OLD.offer_version_id THEN
        RAISE EXCEPTION
            'payment % keeps the offer version it was sold under: its stamp cannot change.', OLD.id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.payment_offer_version_stamp() OWNER TO postgres;

--
-- Name: pricing_plan_family_default(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.pricing_plan_family_default() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.plan_family_id IS NULL THEN
        NEW.plan_family_id := NEW.id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.pricing_plan_family_default() OWNER TO postgres;

--
-- Name: pricing_plan_terms_immutable(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.pricing_plan_terms_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF ( to_jsonb(NEW) - 'superseded_at' - 'updated_at' )
       IS DISTINCT FROM
       ( to_jsonb(OLD) - 'superseded_at' - 'updated_at' )
    THEN
        RAISE EXCEPTION
            'pricing_plans rows are immutable (plan % version %): append a new '
            'version instead of editing this one. Only superseded_at may change.',
            OLD.plan_family_id, OLD.version;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.pricing_plan_terms_immutable() OWNER TO postgres;

--
-- Name: resources_keep_platform_offer_name(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.resources_keep_platform_offer_name() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_TABLE_SCHEMA = 'registry'
       AND EXISTS (SELECT 1 FROM registry.offer_versions v
                     JOIN registry.offer_version_payment_plans p
                       ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                    WHERE v.resource_id = OLD.id
                      AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
                      AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RAISE EXCEPTION 'resource % is what the current platform offer to tenants is for: signup finds it '
                        'by the name payment processing, so it keeps that name', OLD.id;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION registry.resources_keep_platform_offer_name() OWNER TO postgres;

--
-- Name: tenant_domains_updated_at(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.tenant_domains_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.tenant_domains_updated_at() OWNER TO postgres;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: registry; Owner: postgres
--

CREATE FUNCTION registry.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION registry.update_updated_at_column() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: removed_free_platform_plan; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.removed_free_platform_plan (
    id uuid,
    session_id uuid,
    plan_scope character varying(20),
    plan_name text,
    plan_type text,
    pricing_model_type character varying(50),
    currency text,
    requirements jsonb,
    pricing_configuration jsonb,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    amount_cents integer,
    plan_family_id uuid,
    version integer,
    superseded_at timestamp with time zone
);


ALTER TABLE public.removed_free_platform_plan OWNER TO postgres;

--
-- Name: retired_platform_plans; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.retired_platform_plans (
    id uuid,
    session_id uuid,
    plan_scope character varying(20),
    plan_name text,
    plan_type text,
    pricing_model_type character varying(50),
    currency text,
    requirements jsonb,
    pricing_configuration jsonb,
    metadata jsonb,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    amount_cents integer,
    plan_family_id uuid,
    version integer,
    superseded_at timestamp with time zone
);


ALTER TABLE public.retired_platform_plans OWNER TO postgres;

--
-- Name: api_keys; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    key_hash text NOT NULL,
    key_prefix text NOT NULL,
    name text NOT NULL,
    scopes bigint DEFAULT 0 NOT NULL,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE registry.api_keys OWNER TO postgres;

--
-- Name: attendance_records; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.attendance_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_id uuid NOT NULL,
    student_id uuid NOT NULL,
    status text NOT NULL,
    marked_at timestamp with time zone DEFAULT now() NOT NULL,
    marked_by uuid NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    family_member_id uuid,
    CONSTRAINT attendance_records_status_check CHECK ((status = ANY (ARRAY['present'::text, 'absent'::text])))
);


ALTER TABLE registry.attendance_records OWNER TO postgres;

--
-- Name: drop_requests; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.drop_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    enrollment_id uuid NOT NULL,
    requested_by uuid NOT NULL,
    reason text NOT NULL,
    refund_requested boolean DEFAULT false,
    status text DEFAULT 'pending'::text,
    admin_notes text,
    processed_by uuid,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    refund_amount_requested_cents integer,
    CONSTRAINT drop_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text])))
);


ALTER TABLE registry.drop_requests OWNER TO postgres;

--
-- Name: TABLE drop_requests; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON TABLE registry.drop_requests IS 'Requests to drop enrollments that require admin approval';


--
-- Name: enrollments; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.enrollments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid NOT NULL,
    student_id uuid NOT NULL,
    status text DEFAULT 'active'::text,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    family_member_id uuid,
    payment_id uuid,
    parent_id uuid,
    student_type text DEFAULT 'family_member'::text,
    drop_reason text,
    dropped_at timestamp with time zone,
    dropped_by uuid,
    refund_status text DEFAULT 'none'::text,
    transfer_to_session_id uuid,
    transfer_status text DEFAULT 'none'::text,
    refund_amount_cents integer,
    CONSTRAINT enrollments_refund_status_check CHECK ((refund_status = ANY (ARRAY['none'::text, 'pending'::text, 'approved'::text, 'processed'::text, 'denied'::text]))),
    CONSTRAINT enrollments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'cancelled'::text, 'waitlisted'::text]))),
    CONSTRAINT enrollments_student_type_check CHECK ((student_type = ANY (ARRAY['family_member'::text, 'individual'::text, 'group_member'::text, 'corporate'::text]))),
    CONSTRAINT enrollments_transfer_status_check CHECK ((transfer_status = ANY (ARRAY['none'::text, 'requested'::text, 'approved'::text, 'denied'::text, 'completed'::text])))
);


ALTER TABLE registry.enrollments OWNER TO postgres;

--
-- Name: COLUMN enrollments.payment_id; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.payment_id IS 'Reference to payment record for this enrollment';


--
-- Name: COLUMN enrollments.drop_reason; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.drop_reason IS 'Reason why enrollment was dropped';


--
-- Name: COLUMN enrollments.dropped_at; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.dropped_at IS 'Timestamp when enrollment was dropped';


--
-- Name: COLUMN enrollments.dropped_by; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.dropped_by IS 'User who processed the drop (admin or parent)';


--
-- Name: COLUMN enrollments.refund_status; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.refund_status IS 'Status of refund processing for dropped enrollment';


--
-- Name: COLUMN enrollments.transfer_to_session_id; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.transfer_to_session_id IS 'Target session if enrollment was transferred';


--
-- Name: COLUMN enrollments.transfer_status; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.transfer_status IS 'Status of transfer processing';


--
-- Name: COLUMN enrollments.refund_amount_cents; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.refund_amount_cents IS 'Amount refunded for dropped enrollment, in cents';


--
-- Name: entitlement_refunds; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.entitlement_refunds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    entitlement_id uuid NOT NULL,
    amount_cents integer NOT NULL,
    stripe_refund_id text NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT entitlement_refunds_amount_cents_check CHECK ((amount_cents > 0))
);


ALTER TABLE registry.entitlement_refunds OWNER TO postgres;

--
-- Name: entitlement_units; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.entitlement_units (
    entitlement_id uuid NOT NULL,
    resource_id uuid NOT NULL,
    unit integer NOT NULL,
    CONSTRAINT entitlement_units_unit_check CHECK ((unit > 0))
);


ALTER TABLE registry.entitlement_units OWNER TO postgres;

--
-- Name: entitlement_uses; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.entitlement_uses (
    entitlement_id uuid NOT NULL,
    occurrence_id uuid NOT NULL,
    recorded_by uuid,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE registry.entitlement_uses OWNER TO postgres;

--
-- Name: entitlements; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.entitlements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    holder_user_id uuid,
    holder_family_member_id uuid,
    holder_tenant_id uuid,
    payer_user_id uuid,
    offer_version_id uuid NOT NULL,
    payment_plan_id text NOT NULL,
    in_effect tstzrange NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    offer_id uuid NOT NULL,
    plan_kind text,
    state text DEFAULT 'active'::text NOT NULL,
    ended_at timestamp with time zone,
    ended_reason text,
    payment_id uuid,
    payment_share_cents integer,
    CONSTRAINT entitlements_ending_check CHECK (
CASE
    WHEN (state = 'active'::text) THEN ((ended_at IS NULL) AND (ended_reason IS NULL))
    ELSE ((ended_at IS NOT NULL) AND (ended_reason IS NOT NULL) AND (NOT (in_effect && tstzrange(ended_at, NULL::timestamp with time zone))))
END),
    CONSTRAINT entitlements_in_effect_check CHECK (
CASE
    WHEN isempty(in_effect) THEN (state <> 'active'::text)
    ELSE ((NOT lower_inf(in_effect)) AND lower_inc(in_effect) AND (NOT upper_inc(in_effect)))
END),
    CONSTRAINT entitlements_one_holder CHECK ((num_nonnulls(holder_user_id, holder_family_member_id, holder_tenant_id) = 1)),
    CONSTRAINT entitlements_payment_share_check CHECK ((((payment_id IS NULL) = (payment_share_cents IS NULL)) AND (COALESCE(payment_share_cents, 0) >= 0))),
    CONSTRAINT entitlements_state_check CHECK ((state = ANY (ARRAY['active'::text, 'expired'::text, 'refunded'::text, 'dispute_lost'::text])))
);


ALTER TABLE registry.entitlements OWNER TO postgres;

--
-- Name: events; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    "time" timestamp with time zone NOT NULL,
    duration integer DEFAULT 0 NOT NULL,
    location_id uuid NOT NULL,
    project_id uuid NOT NULL,
    teacher_id uuid NOT NULL,
    metadata jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    min_age integer,
    max_age integer,
    capacity integer,
    event_type text DEFAULT 'class'::text,
    status text DEFAULT 'draft'::text,
    CONSTRAINT events_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'closed'::text])))
);


ALTER TABLE registry.events OWNER TO postgres;

--
-- Name: family_members; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.family_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    family_id uuid NOT NULL,
    child_name text NOT NULL,
    birth_date date NOT NULL,
    grade text,
    medical_info jsonb DEFAULT '{}'::jsonb NOT NULL,
    emergency_contact jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE registry.family_members OWNER TO postgres;

--
-- Name: holds; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.holds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    resource_id uuid NOT NULL,
    units integer NOT NULL,
    workflow_run_id uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    state text DEFAULT 'held'::text NOT NULL,
    placed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT holds_state_check CHECK ((state = ANY (ARRAY['held'::text, 'converted'::text, 'released'::text]))),
    CONSTRAINT holds_units_check CHECK ((units > 0))
);


ALTER TABLE registry.holds OWNER TO postgres;

--
-- Name: locations; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.locations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    address_info jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    address_street text,
    address_city text,
    address_state text,
    address_zip text,
    capacity integer,
    contact_info jsonb,
    facilities jsonb,
    latitude numeric(10,8),
    longitude numeric(11,8),
    contact_person_id uuid,
    CONSTRAINT valid_address_info CHECK ((jsonb_typeof(address_info) = 'object'::text))
);


ALTER TABLE registry.locations OWNER TO postgres;

--
-- Name: magic_link_tokens; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.magic_link_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    purpose text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    verified_at timestamp with time zone,
    CONSTRAINT magic_link_tokens_purpose_check CHECK ((purpose = ANY (ARRAY['login'::text, 'invite'::text, 'recovery'::text, 'verify_email'::text])))
);


ALTER TABLE registry.magic_link_tokens OWNER TO postgres;

--
-- Name: message_recipients; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.message_recipients (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id uuid NOT NULL,
    recipient_id uuid NOT NULL,
    recipient_type text DEFAULT 'parent'::text NOT NULL,
    delivered_at timestamp with time zone,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT message_recipients_recipient_type_check CHECK ((recipient_type = ANY (ARRAY['parent'::text, 'teacher'::text, 'admin'::text])))
);


ALTER TABLE registry.message_recipients OWNER TO postgres;

--
-- Name: message_templates; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.message_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    subject_template text NOT NULL,
    body_template text NOT NULL,
    message_type text NOT NULL,
    scope text NOT NULL,
    variables jsonb DEFAULT '{}'::jsonb,
    created_by uuid NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT message_templates_message_type_check CHECK ((message_type = ANY (ARRAY['announcement'::text, 'update'::text, 'emergency'::text]))),
    CONSTRAINT message_templates_scope_check CHECK ((scope = ANY (ARRAY['program'::text, 'session'::text, 'child-specific'::text, 'location'::text, 'tenant-wide'::text])))
);


ALTER TABLE registry.message_templates OWNER TO postgres;

--
-- Name: messages; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    sender_id uuid NOT NULL,
    subject text NOT NULL,
    body text NOT NULL,
    message_type text NOT NULL,
    scope text NOT NULL,
    scope_id uuid,
    scheduled_for timestamp with time zone,
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT messages_message_type_check CHECK ((message_type = ANY (ARRAY['announcement'::text, 'update'::text, 'emergency'::text]))),
    CONSTRAINT messages_scope_check CHECK ((scope = ANY (ARRAY['program'::text, 'session'::text, 'child-specific'::text, 'location'::text, 'tenant-wide'::text])))
);


ALTER TABLE registry.messages OWNER TO postgres;

--
-- Name: notifications; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    type registry.notification_type NOT NULL,
    channel registry.notification_channel NOT NULL,
    subject text NOT NULL,
    message text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    sent_at timestamp with time zone,
    read_at timestamp with time zone,
    failed_at timestamp with time zone,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE registry.notifications OWNER TO postgres;

--
-- Name: offer_version_payment_plans; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.offer_version_payment_plans (
    offer_version_id uuid NOT NULL,
    id text NOT NULL,
    kind text NOT NULL,
    fraction numeric,
    CONSTRAINT offer_version_payment_plans_fraction_check CHECK (((fraction >= (0)::numeric) AND (fraction <= (1)::numeric) AND (scale(fraction) <= 4))),
    CONSTRAINT offer_version_payment_plans_fraction_matches_kind CHECK (((kind = 'percentage_of_sales'::text) = (fraction IS NOT NULL))),
    CONSTRAINT offer_version_payment_plans_id_check CHECK ((id <> ''::text)),
    CONSTRAINT offer_version_payment_plans_kind_check CHECK ((kind = ANY (ARRAY['one_time'::text, 'percentage_of_sales'::text])))
);


ALTER TABLE registry.offer_version_payment_plans OWNER TO postgres;

--
-- Name: offer_versions; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.offer_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    offer_id uuid NOT NULL,
    version integer NOT NULL,
    resource_id uuid,
    published_at timestamp with time zone,
    superseded_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    price_cents integer NOT NULL,
    currency text DEFAULT 'usd'::text NOT NULL,
    units_per_acceptance integer NOT NULL,
    per_booking_cap integer NOT NULL,
    policies jsonb DEFAULT '{}'::jsonb NOT NULL,
    conditions jsonb DEFAULT '[]'::jsonb NOT NULL,
    class_project_id uuid,
    CONSTRAINT offer_versions_buys_resource_or_class CHECK ((num_nonnulls(resource_id, class_project_id) = 1)),
    CONSTRAINT offer_versions_conditions_array CHECK ((jsonb_typeof(conditions) = 'array'::text)),
    CONSTRAINT offer_versions_currency_check CHECK ((currency ~ '^[a-z]{3}$'::text)),
    CONSTRAINT offer_versions_per_booking_cap_check CHECK ((per_booking_cap > 0)),
    CONSTRAINT offer_versions_policies_object CHECK ((jsonb_typeof(policies) = 'object'::text)),
    CONSTRAINT offer_versions_price_cents_check CHECK ((price_cents >= 0)),
    CONSTRAINT offer_versions_published_states_refund CHECK (((published_at IS NULL) OR (policies ? 'refund'::text))),
    CONSTRAINT offer_versions_refund_kind_check CHECK (((NOT (policies ? 'refund'::text)) OR (COALESCE((policies #>> '{refund,kind}'::text[]), ''::text) = ANY (ARRAY['none'::text, 'full_until_cutoff'::text, 'keep_fee_with_admin_exception'::text])))),
    CONSTRAINT offer_versions_superseded_only_if_published CHECK (((superseded_at IS NULL) OR (published_at IS NOT NULL))),
    CONSTRAINT offer_versions_units_per_acceptance_check CHECK ((units_per_acceptance > 0)),
    CONSTRAINT offer_versions_version_check CHECK ((version > 0))
);


ALTER TABLE registry.offer_versions OWNER TO postgres;

--
-- Name: offers; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.offers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE registry.offers OWNER TO postgres;

--
-- Name: outcome_definitions; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.outcome_definitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    schema jsonb NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE registry.outcome_definitions OWNER TO postgres;

--
-- Name: passkeys; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.passkeys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    credential_id bytea NOT NULL,
    public_key bytea NOT NULL,
    sign_count bigint DEFAULT 0 NOT NULL,
    device_name text,
    created_at timestamp with time zone DEFAULT now(),
    last_used_at timestamp with time zone
);


ALTER TABLE registry.passkeys OWNER TO postgres;

--
-- Name: payment_items; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.payment_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_id uuid NOT NULL,
    enrollment_id uuid,
    description text NOT NULL,
    quantity integer DEFAULT 1,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    amount_cents integer DEFAULT 0 NOT NULL,
    pricing_plan_id uuid
);


ALTER TABLE registry.payment_items OWNER TO postgres;

--
-- Name: payments; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    stripe_payment_intent_id character varying(255),
    stripe_payment_method_id character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp with time zone,
    error_message text,
    amount_cents integer DEFAULT 0 NOT NULL,
    refund_owed_cents integer DEFAULT 0 NOT NULL,
    refunded_cents integer DEFAULT 0 NOT NULL,
    refund_seq integer DEFAULT 0 NOT NULL,
    refund_increments jsonb DEFAULT '[]'::jsonb NOT NULL,
    instalment_seq integer,
    instalment_count integer,
    due_date date,
    stripe_schedule_id text,
    platform_fee_cents integer,
    platform_fee_refunded_cents integer,
    platform_offer_version_id uuid,
    platform_payment_plan_id text,
    offer_version_id uuid,
    CONSTRAINT payments_instalment_pair CHECK ((((instalment_seq IS NULL) AND (instalment_count IS NULL)) OR ((instalment_seq IS NOT NULL) AND (instalment_count IS NOT NULL) AND (instalment_seq >= 1) AND (instalment_seq <= instalment_count) AND (instalment_count > 1)))),
    CONSTRAINT payments_platform_fee_cents_check CHECK (((platform_fee_cents IS NULL) OR (platform_fee_cents >= 0))),
    CONSTRAINT payments_platform_fee_refunded_cents_check CHECK (((platform_fee_refunded_cents IS NULL) OR (platform_fee_refunded_cents >= 0))),
    CONSTRAINT payments_refund_increments_cents_integer CHECK ((NOT jsonb_path_exists(refund_increments, '$[*]."cents"?(@ != @.floor() || @.type() != "number")'::jsonpath))),
    CONSTRAINT payments_refund_increments_is_array CHECK ((jsonb_typeof(refund_increments) = 'array'::text)),
    CONSTRAINT payments_refund_owed_cents_check CHECK ((refund_owed_cents >= 0)),
    CONSTRAINT payments_refund_seq_check CHECK ((refund_seq >= 0)),
    CONSTRAINT payments_refund_total_check CHECK (((refund_owed_cents + refunded_cents) <= amount_cents)),
    CONSTRAINT payments_refunded_cents_check CHECK ((refunded_cents >= 0)),
    CONSTRAINT payments_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'processing'::character varying, 'completed'::character varying, 'failed'::character varying, 'refund_pending'::character varying, 'refunded'::character varying, 'partially_refunded'::character varying])::text[])))
);


ALTER TABLE registry.payments OWNER TO postgres;

--
-- Name: COLUMN payments.platform_fee_cents; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.payments.platform_fee_cents IS 'Application fee Stripe reported taking on this charge, in cents. NULL means not recorded: a charge made before this column existed, or one with no destination account. Never derived from a rate -- see #427.';


--
-- Name: COLUMN payments.platform_fee_refunded_cents; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.payments.platform_fee_refunded_cents IS 'Of platform_fee_cents, what Stripe reports returned (application_fee.refunded amount_refunded). NULL means none reported. Raised, never lowered.';


--
-- Name: COLUMN payments.platform_offer_version_id; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.payments.platform_offer_version_id IS 'The platform offer version (registry.offer_versions) the fee above was taken under, from the tenant''s platform entitlement when the payment was created. Not a foreign key: offer versions live in registry, and a superseded version still priced the charge.';


--
-- Name: COLUMN payments.platform_payment_plan_id; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.payments.platform_payment_plan_id IS 'Which of that version''s payment plans the tenant accepted; with the version, the whole stamp.';


--
-- Name: COLUMN payments.offer_version_id; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.payments.offer_version_id IS 'The offer version this charge was sold under, in this schema. Fixed once set.';


--
-- Name: platform_settings; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.platform_settings (
    key text NOT NULL,
    value text,
    description text NOT NULL,
    default_note text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid
);


ALTER TABLE registry.platform_settings OWNER TO postgres;

--
-- Name: COLUMN platform_settings.value; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.platform_settings.value IS 'NULL means not set: the code default applies. Distinct from any value the key accepts.';


--
-- Name: pricing_plans; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.pricing_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid,
    plan_scope character varying(20) DEFAULT 'customer'::character varying,
    plan_name text NOT NULL,
    plan_type text DEFAULT 'standard'::text,
    pricing_model_type character varying(50) DEFAULT 'fixed'::character varying,
    currency text DEFAULT 'USD'::text,
    requirements jsonb DEFAULT '{}'::jsonb,
    pricing_configuration jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    amount_cents integer DEFAULT 0 NOT NULL,
    plan_family_id uuid NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    superseded_at timestamp with time zone,
    CONSTRAINT pricing_plans_percentage_rate_check CHECK (((((pricing_configuration ->> 'percentage'::text) IS NULL) AND ((pricing_model_type)::text <> ALL ((ARRAY['percentage'::character varying, 'hybrid'::character varying, 'revenue_share'::character varying])::text[]))) OR
CASE
    WHEN ((pricing_configuration ->> 'percentage'::text) ~ '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$'::text) THEN (((((pricing_configuration ->> 'percentage'::text))::numeric >= (0)::numeric) AND (((pricing_configuration ->> 'percentage'::text))::numeric <= (1)::numeric)) AND (((pricing_configuration ->> 'percentage'::text))::numeric = round(((pricing_configuration ->> 'percentage'::text))::numeric, 4)))
    ELSE false
END)),
    CONSTRAINT pricing_plans_plan_scope_check CHECK (((plan_scope)::text = ANY ((ARRAY['customer'::character varying, 'tenant'::character varying, 'platform'::character varying])::text[]))),
    CONSTRAINT pricing_plans_pricing_model_type_check CHECK (((pricing_model_type)::text = ANY ((ARRAY['fixed'::character varying, 'percentage'::character varying, 'tiered'::character varying, 'hybrid'::character varying, 'transaction_fee'::character varying])::text[])))
);


ALTER TABLE registry.pricing_plans OWNER TO postgres;

--
-- Name: TABLE pricing_plans; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON TABLE registry.pricing_plans IS 'Defines pricing plans (what is offered) - relationship-agnostic.
WHO gets access is handled by pricing_relationships table.
Plans can have different scopes: customer (B2C), tenant (B2B), or platform (infrastructure).';


--
-- Name: program_types; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.program_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    name text NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE registry.program_types OWNER TO postgres;

--
-- Name: projects; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    metadata jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    program_type_slug text,
    status text DEFAULT 'draft'::text,
    seats_per_occurrence integer,
    CONSTRAINT projects_seats_per_occurrence_check CHECK ((seats_per_occurrence >= 0)),
    CONSTRAINT projects_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'closed'::text])))
);


ALTER TABLE registry.projects OWNER TO postgres;

--
-- Name: resources; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.resources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    kind text NOT NULL,
    capacity integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    event_id uuid,
    CONSTRAINT resources_capacity_matches_kind CHECK ((((kind = 'finite'::text) AND (capacity IS NOT NULL) AND (capacity >= 0)) OR ((kind = 'unbounded'::text) AND (capacity IS NULL)))),
    CONSTRAINT resources_kind_check CHECK ((kind = ANY (ARRAY['finite'::text, 'unbounded'::text]))),
    CONSTRAINT resources_occurrence_is_finite CHECK (((event_id IS NULL) OR (kind = 'finite'::text)))
);


ALTER TABLE registry.resources OWNER TO postgres;

--
-- Name: session_events; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.session_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid NOT NULL,
    event_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE registry.session_events OWNER TO postgres;

--
-- Name: session_teachers; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.session_teachers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid NOT NULL,
    teacher_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE registry.session_teachers OWNER TO postgres;

--
-- Name: sessions; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    metadata jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    session_type text DEFAULT 'regular'::text,
    start_date date,
    end_date date,
    status text DEFAULT 'draft'::text,
    capacity integer,
    waitlist_enabled boolean DEFAULT true NOT NULL,
    CONSTRAINT sessions_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'closed'::text])))
);


ALTER TABLE registry.sessions OWNER TO postgres;

--
-- Name: subscription_events; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.subscription_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid,
    stripe_event_id text NOT NULL,
    event_type text NOT NULL,
    event_data jsonb NOT NULL,
    processed_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    processing_status text DEFAULT 'pending'::text,
    CONSTRAINT subscription_events_processing_status_check CHECK ((processing_status = ANY (ARRAY['pending'::text, 'processed'::text, 'failed'::text])))
);


ALTER TABLE registry.subscription_events OWNER TO postgres;

--
-- Name: templates; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    content text NOT NULL,
    metadata jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE registry.templates OWNER TO postgres;

--
-- Name: tenant_domains; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.tenant_domains (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    domain text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    render_domain_id text,
    verification_error text,
    verified_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT tenant_domains_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'verified'::text, 'failed'::text])))
);


ALTER TABLE registry.tenant_domains OWNER TO postgres;

--
-- Name: tenant_profiles; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.tenant_profiles (
    tenant_id uuid NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    billing_email text,
    billing_phone text,
    billing_address jsonb,
    organization_type text
);


ALTER TABLE registry.tenant_profiles OWNER TO postgres;

--
-- Name: tenant_users; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.tenant_users (
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    role text DEFAULT 'parent'::text NOT NULL,
    CONSTRAINT check_tenant_user_role CHECK ((role = ANY (ARRAY['parent'::text, 'student'::text, 'staff'::text, 'admin'::text])))
);


ALTER TABLE registry.tenant_users OWNER TO postgres;

--
-- Name: tenants; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    stripe_customer_id text,
    stripe_subscription_id text,
    billing_status text DEFAULT 'trial'::text,
    trial_ends_at timestamp with time zone,
    subscription_started_at timestamp with time zone,
    canonical_domain text,
    magic_link_expiry_hours integer DEFAULT 1,
    stripe_connect_account_id text,
    stripe_charges_enabled boolean DEFAULT false NOT NULL,
    stripe_details_submitted boolean DEFAULT false NOT NULL,
    created_from_ip inet,
    CONSTRAINT tenants_billing_status_check CHECK ((billing_status = ANY (ARRAY['trial'::text, 'active'::text, 'past_due'::text, 'cancelled'::text, 'incomplete'::text]))),
    CONSTRAINT tenants_slug_is_lowercase CHECK ((slug = lower(slug)))
);


ALTER TABLE registry.tenants OWNER TO postgres;

--
-- Name: COLUMN tenants.magic_link_expiry_hours; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.tenants.magic_link_expiry_hours IS 'How long a magic link stays redeemable, in hours. Default 1 (#450): the link is a credential and it sits in a mailbox. Registry::DAO::MagicLinkToken and Registry::DAO::Tenant carry the same default as a fallback; t/dao/magic-link-expiry-default.t asserts the three agree.';


--
-- Name: COLUMN tenants.created_from_ip; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.tenants.created_from_ip IS 'Client address that provisioned this tenant; NULL for tenants created before this column, by CLI, or by tests. Used to rate limit provisioning.';


--
-- Name: transfer_requests; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.transfer_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    enrollment_id uuid NOT NULL,
    target_session_id uuid NOT NULL,
    requested_by uuid NOT NULL,
    reason text NOT NULL,
    status text DEFAULT 'pending'::text,
    admin_notes text,
    processed_by uuid,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT transfer_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'completed'::text])))
);


ALTER TABLE registry.transfer_requests OWNER TO postgres;

--
-- Name: TABLE transfer_requests; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON TABLE registry.transfer_requests IS 'Requests to transfer enrollments between sessions';


--
-- Name: user_preferences; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.user_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    preference_key text NOT NULL,
    preference_value jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE registry.user_preferences OWNER TO postgres;

--
-- Name: user_profiles; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.user_profiles (
    user_id uuid NOT NULL,
    email text NOT NULL,
    name text NOT NULL,
    phone text,
    data jsonb,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE registry.user_profiles OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    username text NOT NULL,
    passhash text,
    created_at timestamp with time zone DEFAULT now(),
    birth_date date,
    user_type text DEFAULT 'parent'::text,
    grade text,
    email_verified_at timestamp with time zone,
    invite_pending boolean DEFAULT false,
    deactivated_at timestamp with time zone,
    CONSTRAINT check_user_type CHECK ((user_type = ANY (ARRAY['parent'::text, 'student'::text, 'staff'::text, 'admin'::text])))
);


ALTER TABLE registry.users OWNER TO postgres;

--
-- Name: waitlist; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.waitlist (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid NOT NULL,
    location_id uuid NOT NULL,
    student_id uuid NOT NULL,
    parent_id uuid NOT NULL,
    "position" integer NOT NULL,
    status text DEFAULT 'waiting'::text NOT NULL,
    offered_at timestamp with time zone,
    expires_at timestamp with time zone,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    family_member_id uuid,
    CONSTRAINT waitlist_status_check CHECK ((status = ANY (ARRAY['waiting'::text, 'offered'::text, 'accepted'::text, 'expired'::text, 'declined'::text])))
);


ALTER TABLE registry.waitlist OWNER TO postgres;

--
-- Name: webhook_events; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.webhook_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    stripe_event_id text NOT NULL,
    event_type text,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    account text,
    tenant_id uuid,
    payload jsonb
);


ALTER TABLE registry.webhook_events OWNER TO postgres;

--
-- Name: workflow_runs; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.workflow_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workflow_id uuid NOT NULL,
    latest_step_id uuid,
    continuation_id uuid,
    user_id uuid,
    data jsonb,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE registry.workflow_runs OWNER TO postgres;

--
-- Name: workflow_steps; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.workflow_steps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    description text,
    workflow_id uuid NOT NULL,
    template_id uuid,
    metadata jsonb,
    depends_on uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    class text DEFAULT 'Registry::DAO::WorkflowStep'::text NOT NULL,
    outcome_definition_id uuid,
    label text
);


ALTER TABLE registry.workflow_steps OWNER TO postgres;

--
-- Name: COLUMN workflow_steps.label; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.workflow_steps.label IS 'User-facing name for this step, shown in the workflow progress indicator. NULL means none written: callers fall back to description, then to the slug. Distinct from description, which is a developer note shown in the CLI.';


--
-- Name: workflows; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.workflows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    name text NOT NULL,
    description text,
    first_step text DEFAULT 'landing'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE registry.workflows OWNER TO postgres;

--
-- Name: changes; Type: TABLE; Schema: sqitch; Owner: postgres
--

CREATE TABLE sqitch.changes (
    change_id text NOT NULL,
    script_hash text,
    change text NOT NULL,
    project text NOT NULL,
    note text DEFAULT ''::text NOT NULL,
    committed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    committer_name text NOT NULL,
    committer_email text NOT NULL,
    planned_at timestamp with time zone NOT NULL,
    planner_name text NOT NULL,
    planner_email text NOT NULL
);


ALTER TABLE sqitch.changes OWNER TO postgres;

--
-- Name: TABLE changes; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON TABLE sqitch.changes IS 'Tracks the changes currently deployed to the database.';


--
-- Name: COLUMN changes.change_id; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.change_id IS 'Change primary key.';


--
-- Name: COLUMN changes.script_hash; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.script_hash IS 'Deploy script SHA-1 hash.';


--
-- Name: COLUMN changes.change; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.change IS 'Name of a deployed change.';


--
-- Name: COLUMN changes.project; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.project IS 'Name of the Sqitch project to which the change belongs.';


--
-- Name: COLUMN changes.note; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.note IS 'Description of the change.';


--
-- Name: COLUMN changes.committed_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.committed_at IS 'Date the change was deployed.';


--
-- Name: COLUMN changes.committer_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.committer_name IS 'Name of the user who deployed the change.';


--
-- Name: COLUMN changes.committer_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.committer_email IS 'Email address of the user who deployed the change.';


--
-- Name: COLUMN changes.planned_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.planned_at IS 'Date the change was added to the plan.';


--
-- Name: COLUMN changes.planner_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.planner_name IS 'Name of the user who planed the change.';


--
-- Name: COLUMN changes.planner_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.changes.planner_email IS 'Email address of the user who planned the change.';


--
-- Name: dependencies; Type: TABLE; Schema: sqitch; Owner: postgres
--

CREATE TABLE sqitch.dependencies (
    change_id text NOT NULL,
    type text NOT NULL,
    dependency text NOT NULL,
    dependency_id text,
    CONSTRAINT dependencies_check CHECK ((((type = 'require'::text) AND (dependency_id IS NOT NULL)) OR ((type = 'conflict'::text) AND (dependency_id IS NULL))))
);


ALTER TABLE sqitch.dependencies OWNER TO postgres;

--
-- Name: TABLE dependencies; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON TABLE sqitch.dependencies IS 'Tracks the currently satisfied dependencies.';


--
-- Name: COLUMN dependencies.change_id; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.dependencies.change_id IS 'ID of the depending change.';


--
-- Name: COLUMN dependencies.type; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.dependencies.type IS 'Type of dependency.';


--
-- Name: COLUMN dependencies.dependency; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.dependencies.dependency IS 'Dependency name.';


--
-- Name: COLUMN dependencies.dependency_id; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.dependencies.dependency_id IS 'Change ID the dependency resolves to.';


--
-- Name: events; Type: TABLE; Schema: sqitch; Owner: postgres
--

CREATE TABLE sqitch.events (
    event text NOT NULL,
    change_id text NOT NULL,
    change text NOT NULL,
    project text NOT NULL,
    note text DEFAULT ''::text NOT NULL,
    requires text[] DEFAULT '{}'::text[] NOT NULL,
    conflicts text[] DEFAULT '{}'::text[] NOT NULL,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    committed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    committer_name text NOT NULL,
    committer_email text NOT NULL,
    planned_at timestamp with time zone NOT NULL,
    planner_name text NOT NULL,
    planner_email text NOT NULL,
    CONSTRAINT events_event_check CHECK ((event = ANY (ARRAY['deploy'::text, 'revert'::text, 'fail'::text, 'merge'::text])))
);


ALTER TABLE sqitch.events OWNER TO postgres;

--
-- Name: TABLE events; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON TABLE sqitch.events IS 'Contains full history of all deployment events.';


--
-- Name: COLUMN events.event; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.event IS 'Type of event.';


--
-- Name: COLUMN events.change_id; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.change_id IS 'Change ID.';


--
-- Name: COLUMN events.change; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.change IS 'Change name.';


--
-- Name: COLUMN events.project; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.project IS 'Name of the Sqitch project to which the change belongs.';


--
-- Name: COLUMN events.note; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.note IS 'Description of the change.';


--
-- Name: COLUMN events.requires; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.requires IS 'Array of the names of required changes.';


--
-- Name: COLUMN events.conflicts; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.conflicts IS 'Array of the names of conflicting changes.';


--
-- Name: COLUMN events.tags; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.tags IS 'Tags associated with the change.';


--
-- Name: COLUMN events.committed_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.committed_at IS 'Date the event was committed.';


--
-- Name: COLUMN events.committer_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.committer_name IS 'Name of the user who committed the event.';


--
-- Name: COLUMN events.committer_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.committer_email IS 'Email address of the user who committed the event.';


--
-- Name: COLUMN events.planned_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.planned_at IS 'Date the event was added to the plan.';


--
-- Name: COLUMN events.planner_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.planner_name IS 'Name of the user who planed the change.';


--
-- Name: COLUMN events.planner_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.events.planner_email IS 'Email address of the user who plan planned the change.';


--
-- Name: projects; Type: TABLE; Schema: sqitch; Owner: postgres
--

CREATE TABLE sqitch.projects (
    project text NOT NULL,
    uri text,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    creator_name text NOT NULL,
    creator_email text NOT NULL
);


ALTER TABLE sqitch.projects OWNER TO postgres;

--
-- Name: TABLE projects; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON TABLE sqitch.projects IS 'Sqitch projects deployed to this database.';


--
-- Name: COLUMN projects.project; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.projects.project IS 'Unique Name of a project.';


--
-- Name: COLUMN projects.uri; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.projects.uri IS 'Optional project URI';


--
-- Name: COLUMN projects.created_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.projects.created_at IS 'Date the project was added to the database.';


--
-- Name: COLUMN projects.creator_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.projects.creator_name IS 'Name of the user who added the project.';


--
-- Name: COLUMN projects.creator_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.projects.creator_email IS 'Email address of the user who added the project.';


--
-- Name: releases; Type: TABLE; Schema: sqitch; Owner: postgres
--

CREATE TABLE sqitch.releases (
    version real NOT NULL,
    installed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    installer_name text NOT NULL,
    installer_email text NOT NULL
);


ALTER TABLE sqitch.releases OWNER TO postgres;

--
-- Name: TABLE releases; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON TABLE sqitch.releases IS 'Sqitch registry releases.';


--
-- Name: COLUMN releases.version; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.releases.version IS 'Version of the Sqitch registry.';


--
-- Name: COLUMN releases.installed_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.releases.installed_at IS 'Date the registry release was installed.';


--
-- Name: COLUMN releases.installer_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.releases.installer_name IS 'Name of the user who installed the registry release.';


--
-- Name: COLUMN releases.installer_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.releases.installer_email IS 'Email address of the user who installed the registry release.';


--
-- Name: tags; Type: TABLE; Schema: sqitch; Owner: postgres
--

CREATE TABLE sqitch.tags (
    tag_id text NOT NULL,
    tag text NOT NULL,
    project text NOT NULL,
    change_id text NOT NULL,
    note text DEFAULT ''::text NOT NULL,
    committed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    committer_name text NOT NULL,
    committer_email text NOT NULL,
    planned_at timestamp with time zone NOT NULL,
    planner_name text NOT NULL,
    planner_email text NOT NULL
);


ALTER TABLE sqitch.tags OWNER TO postgres;

--
-- Name: TABLE tags; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON TABLE sqitch.tags IS 'Tracks the tags currently applied to the database.';


--
-- Name: COLUMN tags.tag_id; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.tag_id IS 'Tag primary key.';


--
-- Name: COLUMN tags.tag; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.tag IS 'Project-unique tag name.';


--
-- Name: COLUMN tags.project; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.project IS 'Name of the Sqitch project to which the tag belongs.';


--
-- Name: COLUMN tags.change_id; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.change_id IS 'ID of last change deployed before the tag was applied.';


--
-- Name: COLUMN tags.note; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.note IS 'Description of the tag.';


--
-- Name: COLUMN tags.committed_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.committed_at IS 'Date the tag was applied to the database.';


--
-- Name: COLUMN tags.committer_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.committer_name IS 'Name of the user who applied the tag.';


--
-- Name: COLUMN tags.committer_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.committer_email IS 'Email address of the user who applied the tag.';


--
-- Name: COLUMN tags.planned_at; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.planned_at IS 'Date the tag was added to the plan.';


--
-- Name: COLUMN tags.planner_name; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.planner_name IS 'Name of the user who planed the tag.';


--
-- Name: COLUMN tags.planner_email; Type: COMMENT; Schema: sqitch; Owner: postgres
--

COMMENT ON COLUMN sqitch.tags.planner_email IS 'Email address of the user who planned the tag.';


--
-- Data for Name: removed_free_platform_plan; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.removed_free_platform_plan (id, session_id, plan_scope, plan_name, plan_type, pricing_model_type, currency, requirements, pricing_configuration, metadata, created_at, updated_at, amount_cents, plan_family_id, version, superseded_at) FROM stdin;
8ae40a1f-8702-410c-9cd9-9e2c118deb96	\N	platform	Registry Free	standard	percentage	USD	{}	{"applies_to": "customer_payments", "percentage": 0.00, "minimum_monthly": 0, "refund_application_fee": true}	{"default": true, "description": "Platform fallback: no revenue share"}	2026-11-25 01:24:21.147798+00	2026-11-25 01:24:21.147798+00	0	8ae40a1f-8702-410c-9cd9-9e2c118deb96	1	\N
\.


--
-- Data for Name: retired_platform_plans; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.retired_platform_plans (id, session_id, plan_scope, plan_name, plan_type, pricing_model_type, currency, requirements, pricing_configuration, metadata, created_at, updated_at, amount_cents, plan_family_id, version, superseded_at) FROM stdin;
a4df35df-cb3c-48f7-80f2-340c7ca7bc62	\N	tenant	Registry Standard - $200/month	subscription	fixed	USD	{}	{"includes": ["unlimited_programs", "unlimited_enrollments", "email_support"], "monthly_amount": 200.00}	{"default": true, "description": "Standard monthly subscription"}	2026-11-25 01:24:18.67472+00	2026-11-25 01:24:18.67472+00	20000	a4df35df-cb3c-48f7-80f2-340c7ca7bc62	1	\N
14c2ea81-f1a1-42bf-8e0a-545b514714bd	\N	tenant	Registry Plus - $100/month + 1%	hybrid	hybrid	USD	{}	{"applies_to": "customer_payments", "percentage": 0.01, "monthly_base": 100.00}	{"default": false, "description": "Reduced monthly fee with revenue share"}	2026-11-25 01:24:18.67472+00	2026-11-25 01:24:18.67472+00	10000	14c2ea81-f1a1-42bf-8e0a-545b514714bd	1	\N
3eb51f2a-87aa-424f-901c-0e5a470b6bfd	\N	tenant	Studio	standard	hybrid	USD	{}	{"applies_to": "customer_payments", "percentage": 0.02, "description": "Everything in Solo, plus multi-location scheduling", "refund_application_fee": true}	{"coming_soon": true, "description": "Everything in Solo, plus multi-location scheduling", "seeded_tier": "Studio", "display_order": 2, "created_by_migration": "seed-tier-pricing-options"}	2026-11-25 01:24:22.935107+00	2026-11-25 01:24:22.935107+00	19900	3eb51f2a-87aa-424f-901c-0e5a470b6bfd	1	\N
dabfc745-7163-420b-8fa6-e7e21ba66d5f	\N	tenant	Empire	standard	hybrid	USD	{}	{"applies_to": "customer_payments", "percentage": 0.01, "description": "Everything in Studio, plus priority support", "refund_application_fee": true}	{"coming_soon": true, "description": "Everything in Studio, plus priority support", "seeded_tier": "Empire", "display_order": 3, "created_by_migration": "seed-tier-pricing-options"}	2026-11-25 01:24:22.935107+00	2026-11-25 01:24:22.935107+00	99900	dabfc745-7163-420b-8fa6-e7e21ba66d5f	1	\N
\.


--
-- Data for Name: api_keys; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.api_keys (id, user_id, key_hash, key_prefix, name, scopes, expires_at, last_used_at, created_at) FROM stdin;
\.


--
-- Data for Name: attendance_records; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.attendance_records (id, event_id, student_id, status, marked_at, marked_by, notes, created_at, updated_at, family_member_id) FROM stdin;
\.


--
-- Data for Name: drop_requests; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.drop_requests (id, enrollment_id, requested_by, reason, refund_requested, status, admin_notes, processed_by, processed_at, created_at, updated_at, refund_amount_requested_cents) FROM stdin;
\.


--
-- Data for Name: enrollments; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.enrollments (id, session_id, student_id, status, metadata, created_at, updated_at, family_member_id, payment_id, parent_id, student_type, drop_reason, dropped_at, dropped_by, refund_status, transfer_to_session_id, transfer_status, refund_amount_cents) FROM stdin;
\.


--
-- Data for Name: entitlement_refunds; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.entitlement_refunds (id, entitlement_id, amount_cents, stripe_refund_id, recorded_at) FROM stdin;
\.


--
-- Data for Name: entitlement_units; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.entitlement_units (entitlement_id, resource_id, unit) FROM stdin;
\.


--
-- Data for Name: entitlement_uses; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.entitlement_uses (entitlement_id, occurrence_id, recorded_by, recorded_at) FROM stdin;
\.


--
-- Data for Name: entitlements; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.entitlements (id, holder_user_id, holder_family_member_id, holder_tenant_id, payer_user_id, offer_version_id, payment_plan_id, in_effect, created_at, offer_id, plan_kind, state, ended_at, ended_reason, payment_id, payment_share_cents) FROM stdin;
00000000-0000-0000-0004-000000000002	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0000-0003-000000000002	revenue_share	["2026-11-25 01:24:26.904871+00",)	2026-11-25 01:24:26.904871+00	00000000-0000-0000-0002-000000000002	percentage_of_sales	active	\N	\N	\N	\N
00000000-0000-0000-0004-000000000003	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0000-0003-000000000003	one_time	["2026-11-25 01:24:26.904871+00",)	2026-11-25 01:24:26.904871+00	00000000-0000-0000-0002-000000000003	one_time	active	\N	\N	\N	\N
00000000-0000-0000-0004-000000000011	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0000-0003-000000000011	one_time	["2026-11-25 01:24:26.904871+00",)	2026-11-25 01:24:26.904871+00	00000000-0000-0000-0002-000000000011	one_time	active	\N	\N	\N	\N
00000000-0000-0000-0004-000000000012	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0000-0003-000000000012	one_time	["2026-11-25 01:24:26.904871+00",)	2026-11-25 01:24:26.904871+00	00000000-0000-0000-0002-000000000012	one_time	active	\N	\N	\N	\N
00000000-0000-0000-0004-000000000013	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0000-0003-000000000013	one_time	["2026-11-25 01:24:26.904871+00",)	2026-11-25 01:24:26.904871+00	00000000-0000-0000-0002-000000000013	one_time	active	\N	\N	\N	\N
00000000-0000-0000-0004-000000000014	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0000-0003-000000000014	one_time	["2026-11-25 01:24:26.904871+00",)	2026-11-25 01:24:26.904871+00	00000000-0000-0000-0002-000000000014	one_time	active	\N	\N	\N	\N
00000000-0000-0000-0004-000000000015	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0000-0003-000000000015	one_time	["2026-11-25 01:24:26.904871+00",)	2026-11-25 01:24:26.904871+00	00000000-0000-0000-0002-000000000015	one_time	active	\N	\N	\N	\N
00000000-0000-0001-0004-000000000001	\N	\N	00000000-0000-0000-0000-000000000000	\N	00000000-0000-0001-0003-000000000001	one_time	["2026-11-25 01:24:27.137444+00",)	2026-11-25 01:24:27.137444+00	00000000-0000-0001-0002-000000000001	one_time	active	\N	\N	\N	\N
\.


--
-- Data for Name: events; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.events (id, "time", duration, location_id, project_id, teacher_id, metadata, notes, created_at, updated_at, min_age, max_age, capacity, event_type, status) FROM stdin;
b92b11fc-f788-4a55-aa3e-0742fa48b8bd	2026-11-25 01:24:19.797717+00	0	8347290d-7a1f-480a-8db2-49ad4ed74059	8665cf23-0f43-43ff-a7f3-690114c2b4ed	68d63719-0351-4184-9607-434b9fbe52b1	\N	\N	2026-11-25 01:24:19.797717+00	2026-11-25 01:24:19.797717	\N	\N	999999	registration	published
\.


--
-- Data for Name: family_members; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.family_members (id, family_id, child_name, birth_date, grade, medical_info, emergency_contact, notes, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: holds; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.holds (id, resource_id, units, workflow_run_id, expires_at, state, placed_at) FROM stdin;
\.


--
-- Data for Name: locations; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.locations (id, name, slug, address_info, metadata, notes, created_at, updated_at, address_street, address_city, address_state, address_zip, capacity, contact_info, facilities, latitude, longitude, contact_person_id) FROM stdin;
8347290d-7a1f-480a-8db2-49ad4ed74059	Online	online	{"type": "virtual"}	\N	\N	2026-11-25 01:24:19.795458+00	2026-11-25 01:24:19.795458	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N
\.


--
-- Data for Name: magic_link_tokens; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.magic_link_tokens (id, user_id, token_hash, purpose, expires_at, consumed_at, created_at, verified_at) FROM stdin;
\.


--
-- Data for Name: message_recipients; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.message_recipients (id, message_id, recipient_id, recipient_type, delivered_at, read_at, created_at) FROM stdin;
\.


--
-- Data for Name: message_templates; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.message_templates (id, name, subject_template, body_template, message_type, scope, variables, created_by, is_active, created_at, updated_at) FROM stdin;
aec5ec51-3c09-465d-9160-745b8d3d71d6	Program Announcement	Important Update: {{program_name}}	Dear {{parent_name}},\n\nWe have an important announcement regarding {{program_name}}.\n\n{{announcement_details}}\n\nIf you have any questions, please don't hesitate to contact us.\n\nBest regards,\n{{sender_name}}\n{{organization_name}}	announcement	program	{"parent_name": "Parent's name", "sender_name": "Staff member name", "program_name": "Name of the program", "organization_name": "Organization name", "announcement_details": "Details of the announcement"}	00000000-0000-0000-0000-000000000000	t	2026-11-25 01:24:17.107001+00	2026-11-25 01:24:17.107001+00
f4a94b75-327c-441c-a0b8-9db9b3c23bec	Session Update	Session Update: {{session_name}}	Dear {{parent_name}},\n\nWe wanted to update you about {{session_name}} for {{child_name}}.\n\n{{update_details}}\n\nThank you for your understanding.\n\nBest regards,\n{{sender_name}}	update	session	{"child_name": "Child's name", "parent_name": "Parent's name", "sender_name": "Staff member name", "session_name": "Name of the session", "update_details": "Details of the update"}	00000000-0000-0000-0000-000000000000	t	2026-11-25 01:24:17.107001+00	2026-11-25 01:24:17.107001+00
270ee23a-fee5-4a08-a512-5c39d9954f70	Emergency Alert	URGENT: {{emergency_title}}	Dear {{parent_name}},\n\nThis is an urgent message regarding {{scope_description}}.\n\n{{emergency_details}}\n\nPlease take immediate action as needed.\n\n{{contact_information}}\n\n{{sender_name}}\n{{organization_name}}	emergency	tenant-wide	{"parent_name": "Parent's name", "sender_name": "Staff member name", "emergency_title": "Title of emergency", "emergency_details": "Emergency details", "organization_name": "Organization name", "scope_description": "What the emergency affects", "contact_information": "Emergency contact info"}	00000000-0000-0000-0000-000000000000	t	2026-11-25 01:24:17.107001+00	2026-11-25 01:24:17.107001+00
\.


--
-- Data for Name: messages; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.messages (id, sender_id, subject, body, message_type, scope, scope_id, scheduled_for, sent_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: notifications; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.notifications (id, user_id, type, channel, subject, message, metadata, sent_at, read_at, failed_at, failure_reason, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: offer_version_payment_plans; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.offer_version_payment_plans (offer_version_id, id, kind, fraction) FROM stdin;
00000000-0000-0000-0003-000000000001	revenue_share	percentage_of_sales	0.025
00000000-0000-0000-0003-000000000002	revenue_share	percentage_of_sales	0
00000000-0000-0000-0003-000000000003	one_time	one_time	\N
00000000-0000-0000-0003-000000000011	one_time	one_time	\N
00000000-0000-0000-0003-000000000012	one_time	one_time	\N
00000000-0000-0000-0003-000000000013	one_time	one_time	\N
00000000-0000-0000-0003-000000000014	one_time	one_time	\N
00000000-0000-0000-0003-000000000015	one_time	one_time	\N
00000000-0000-0001-0003-000000000001	one_time	one_time	\N
\.


--
-- Data for Name: offer_versions; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.offer_versions (id, offer_id, version, resource_id, published_at, superseded_at, created_at, price_cents, currency, units_per_acceptance, per_booking_cap, policies, conditions, class_project_id) FROM stdin;
00000000-0000-0000-0003-000000000001	00000000-0000-0000-0002-000000000001	1	00000000-0000-0000-0001-000000000001	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"use": {"kind": "none"}, "change": {"kind": "none"}, "expiry": {"kind": "never"}, "refund": {"kind": "keep_fee_with_admin_exception"}}	[]	\N
00000000-0000-0000-0003-000000000002	00000000-0000-0000-0002-000000000002	1	00000000-0000-0000-0001-000000000001	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
00000000-0000-0000-0003-000000000003	00000000-0000-0000-0002-000000000003	1	00000000-0000-0000-0001-000000000002	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
00000000-0000-0000-0003-000000000011	00000000-0000-0000-0002-000000000011	1	00000000-0000-0000-0001-000000000011	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
00000000-0000-0000-0003-000000000012	00000000-0000-0000-0002-000000000012	1	00000000-0000-0000-0001-000000000012	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
00000000-0000-0000-0003-000000000013	00000000-0000-0000-0002-000000000013	1	00000000-0000-0000-0001-000000000013	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
00000000-0000-0000-0003-000000000014	00000000-0000-0000-0002-000000000014	1	00000000-0000-0000-0001-000000000014	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
00000000-0000-0000-0003-000000000015	00000000-0000-0000-0002-000000000015	1	00000000-0000-0000-0001-000000000015	2026-11-25 01:24:26.904871+00	\N	2026-11-25 01:24:26.904871+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
00000000-0000-0001-0003-000000000001	00000000-0000-0001-0002-000000000001	1	00000000-0000-0001-0001-000000000001	2026-11-25 01:24:27.137444+00	\N	2026-11-25 01:24:27.137444+00	0	usd	1	1	{"refund": {"kind": "none"}}	[{"kind": "holder_is_offerer"}]	\N
\.


--
-- Data for Name: offers; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.offers (id, name, created_at) FROM stdin;
00000000-0000-0000-0002-000000000001	Solo	2026-11-25 01:24:26.904871+00
00000000-0000-0000-0002-000000000002	Platform payment processing	2026-11-25 01:24:26.904871+00
00000000-0000-0000-0002-000000000003	Platform email sending	2026-11-25 01:24:26.904871+00
00000000-0000-0000-0002-000000000011	Platform run offer-publishing	2026-11-25 01:24:26.904871+00
00000000-0000-0000-0002-000000000012	Platform run program-creation	2026-11-25 01:24:26.904871+00
00000000-0000-0000-0002-000000000013	Platform run program-setup	2026-11-25 01:24:26.904871+00
00000000-0000-0000-0002-000000000014	Platform run session-creation	2026-11-25 01:24:26.904871+00
00000000-0000-0000-0002-000000000015	Platform run event-creation	2026-11-25 01:24:26.904871+00
00000000-0000-0001-0002-000000000001	Platform operator right	2026-11-25 01:24:27.137444+00
\.


--
-- Data for Name: outcome_definitions; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.outcome_definitions (id, name, description, schema, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: passkeys; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.passkeys (id, user_id, credential_id, public_key, sign_count, device_name, created_at, last_used_at) FROM stdin;
\.


--
-- Data for Name: payment_items; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.payment_items (id, payment_id, enrollment_id, description, quantity, metadata, created_at, amount_cents, pricing_plan_id) FROM stdin;
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.payments (id, user_id, currency, status, stripe_payment_intent_id, stripe_payment_method_id, metadata, created_at, updated_at, completed_at, error_message, amount_cents, refund_owed_cents, refunded_cents, refund_seq, refund_increments, instalment_seq, instalment_count, due_date, stripe_schedule_id, platform_fee_cents, platform_fee_refunded_cents, platform_offer_version_id, platform_payment_plan_id, offer_version_id) FROM stdin;
\.


--
-- Data for Name: platform_settings; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.platform_settings (key, value, description, default_note, updated_at, updated_by) FROM stdin;
inert_tenant_days	\N	How long a tenant may sit unused before `registry tenant inert` reports it as abandoned. Set to 0 for never.	Not set: 90 days.	2026-11-25 01:24:24.107727+00	\N
unverified_tenant_daily_mail_cap	\N	How many bulk messages a day a tenant may send before its own domain is verified. Announcements and updates only -- sign-in links, enrolment confirmations and emergencies are never capped. Set to 0 to hold all bulk mail from unverified tenants.	Not set: 200 a day.	2026-11-25 01:24:24.651085+00	\N
\.


--
-- Data for Name: pricing_plans; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.pricing_plans (id, session_id, plan_scope, plan_name, plan_type, pricing_model_type, currency, requirements, pricing_configuration, metadata, created_at, updated_at, amount_cents, plan_family_id, version, superseded_at) FROM stdin;
b985b401-5a8e-4902-a856-43e55a846ee7	\N	tenant	Solo	revenue_share	percentage	USD	{}	{"applies_to": "customer_payments", "percentage": 0.025, "description": "Revenue share on customer payments. No monthly fee, no minimums.", "minimum_monthly": 0, "refund_application_fee": true}	{"default": false, "featured": true, "launch_rate": true, "display_order": 1}	2026-11-25 01:24:18.67472+00	2026-11-25 01:24:22.935107+00	0	b985b401-5a8e-4902-a856-43e55a846ee7	1	\N
\.


--
-- Data for Name: program_types; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.program_types (id, slug, name, config, created_at, updated_at) FROM stdin;
d583997e-86a9-402e-9d8e-bf271f6c4eb7	afterschool	After School Program	{"standard_times": {"friday": "15:00", "monday": "15:00", "tuesday": "15:00", "thursday": "15:00", "wednesday": "14:00"}, "session_pattern": "weekly_for_x_weeks", "enrollment_rules": {"same_session_for_siblings": true}}	2026-11-25 01:24:15.939918+00	2026-11-25 01:24:15.939918
f53123fd-4984-4a03-b5fb-652da929bd59	summer-camp	Summer Camp	{"standard_times": {"end": "15:00", "start": "09:00"}, "session_pattern": "daily_for_x_days", "enrollment_rules": {"same_session_for_siblings": false}}	2026-11-25 01:24:15.939918+00	2026-11-25 01:24:15.939918
\.


--
-- Data for Name: projects; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.projects (id, name, slug, metadata, notes, created_at, updated_at, program_type_slug, status, seats_per_occurrence) FROM stdin;
8665cf23-0f43-43ff-a7f3-690114c2b4ed	Tiny Art Empire	tiny-art-empire	{"registration_workflow": "tenant-signup"}	Start your own art education business. Create programs, manage enrollments, accept payments — all in one platform.	2026-11-25 01:24:19.795971+00	2026-11-25 01:24:19.795971	\N	draft	\N
\.


--
-- Data for Name: resources; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.resources (id, name, kind, capacity, created_at, event_id) FROM stdin;
00000000-0000-0000-0001-000000000001	payment processing	unbounded	\N	2026-11-25 01:24:26.904871+00	\N
00000000-0000-0000-0001-000000000002	email sending	unbounded	\N	2026-11-25 01:24:26.904871+00	\N
00000000-0000-0000-0001-000000000011	run:offer-publishing	unbounded	\N	2026-11-25 01:24:26.904871+00	\N
00000000-0000-0000-0001-000000000012	run:program-creation	unbounded	\N	2026-11-25 01:24:26.904871+00	\N
00000000-0000-0000-0001-000000000013	run:program-setup	unbounded	\N	2026-11-25 01:24:26.904871+00	\N
00000000-0000-0000-0001-000000000014	run:session-creation	unbounded	\N	2026-11-25 01:24:26.904871+00	\N
00000000-0000-0000-0001-000000000015	run:event-creation	unbounded	\N	2026-11-25 01:24:26.904871+00	\N
00000000-0000-0001-0001-000000000001	operator	unbounded	\N	2026-11-25 01:24:27.137444+00	\N
\.


--
-- Data for Name: session_events; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.session_events (id, session_id, event_id, created_at, updated_at) FROM stdin;
3eb6dccf-045b-494b-bb28-c78f9755660d	c0a263fd-f0a5-4174-bf34-488b9d355fee	b92b11fc-f788-4a55-aa3e-0742fa48b8bd	2026-11-25 01:24:19.799163+00	2026-11-25 01:24:19.799163
\.


--
-- Data for Name: session_teachers; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.session_teachers (id, session_id, teacher_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: sessions; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.sessions (id, name, slug, metadata, notes, created_at, updated_at, session_type, start_date, end_date, status, capacity, waitlist_enabled) FROM stdin;
c0a263fd-f0a5-4174-bf34-488b9d355fee	Get Started Today	get-started	\N	\N	2026-11-25 01:24:19.797068+00	2026-11-25 01:24:19.797068	regular	2026-11-25	2036-11-25	published	999999	t
\.


--
-- Data for Name: subscription_events; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.subscription_events (id, tenant_id, stripe_event_id, event_type, event_data, processed_at, processing_status) FROM stdin;
\.


--
-- Data for Name: templates; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.templates (id, name, slug, content, metadata, notes, created_at, updated_at) FROM stdin;
24930497-ef0f-44c8-9a94-956356e5e46c	tenant-storefront/program-listing	tenant-storefront-program-listing	% layout 'default';\n% title 'Tiny Art Empire';\n% stash no_container => 1, enable_background_effects => 1;\n\n% # Extract data for callcc form\n% my $prog = $programs->[0] || {};\n% my $project = $prog->{project};\n% my $sess_info = ($prog->{sessions} || [])->[0] || {};\n% my $session = $sess_info->{session};\n% my $reg_workflow = ($project && $project->metadata || {})->{registration_workflow} || 'tenant-signup';\n\n<div class="landing-page">\n  <nav class="landing-nav">\n    <div class="landing-logo">Tiny Art Empire</div>\n  </nav>\n\n  <!-- Hero: The Why -->\n  <section class="landing-hero">\n    <h1>Your art deserves a real business.</h1>\n    <p class="landing-hero-subtitle">\n      Everything you need to fill classes, get paid, and stay organized\n      -- so you can get back to making art.\n    </p>\n    <div class="landing-cta-container">\n      % if ($project && $session) {\n        <form method="POST"\n              action="/registry-storefront/<%= $run->id %>/callcc/<%= $reg_workflow %>">\n          <input type="hidden" name="session_id" value="<%= $session->id %>">\n          <input type="hidden" name="program_id" value="<%= $project->id %>">\n          <button type="submit" class="landing-cta-button">Get Started</button>\n        </form>\n      % } else {\n        <a href="<%= url_for('workflow_start', workflow => 'tenant-signup') %>" class="landing-cta-button">\n          Get Started\n        </a>\n      % }\n    </div>\n  </section>\n\n  <!-- Problem Cards: The How -->\n  <section class="landing-features">\n    <div class="landing-features-container">\n      <h2>Less paperwork. More studio time.</h2>\n      <div class="landing-features-grid" style="grid-template-columns: repeat(3, 1fr);">\n        <article class="landing-feature-card">\n          <h3 class="landing-feature-title">Fill your classes without the hustle</h3>\n          <p class="landing-feature-description">\n            Parents find your programs and register online -- no back-and-forth\n            emails or paper forms.\n          </p>\n        </article>\n        <article class="landing-feature-card">\n          <h3 class="landing-feature-title">Get paid before class starts</h3>\n          <p class="landing-feature-description">\n            Online payments at registration. No chasing checks, no awkward reminders.\n          </p>\n        </article>\n        <article class="landing-feature-card">\n          <h3 class="landing-feature-title">One place for all of it</h3>\n          <p class="landing-feature-description">\n            Scheduling, attendance, waitlists, and families with three kids -- handled.\n          </p>\n        </article>\n        <article class="landing-feature-card">\n          <h3 class="landing-feature-title">Keep parents in the loop</h3>\n          <p class="landing-feature-description">\n            Automatic updates and notifications so you're not writing the same\n            email twelve times.\n          </p>\n        </article>\n        <article class="landing-feature-card">\n          <h3 class="landing-feature-title">See how your business is doing</h3>\n          <p class="landing-feature-description">\n            Plain-English reports on revenue, enrollment, and trends.\n            No spreadsheet required.\n          </p>\n        </article>\n        <article class="landing-feature-card">\n          <h3 class="landing-feature-title">Grow when you're ready</h3>\n          <p class="landing-feature-description">\n            Add instructors, locations, and programs without adding chaos.\n          </p>\n        </article>\n      </div>\n    </div>\n  </section>\n\n  <!-- Alignment: The Trust -->\n  <section class="landing-features">\n    <div class="landing-features-container" style="text-align: center;">\n      <h2>Free to Start</h2>\n      <p class="landing-hero-subtitle">\n        There are no monthly fees, no set up fees. We have a 2.5% revenue\n        share, so we only make money when you do. Our entire job is to help\n        you succeed!\n      </p>\n      <div class="landing-cta-container">\n        % if ($project && $session) {\n          <form method="POST"\n                action="/registry-storefront/<%= $run->id %>/callcc/<%= $reg_workflow %>">\n            <input type="hidden" name="session_id" value="<%= $session->id %>">\n            <input type="hidden" name="program_id" value="<%= $project->id %>">\n            <button type="submit" class="landing-cta-button">Get Started</button>\n          </form>\n        % } else {\n          <a href="<%= url_for('workflow_start', workflow => 'tenant-signup') %>" class="landing-cta-button">\n            Get Started\n          </a>\n        % }\n      </div>\n    </div>\n  </section>\n\n  <footer style="text-align: center; padding: var(--space-8); color: var(--landing-text-secondary); font-size: var(--font-size-sm);">\n    <p>A <strong>Tamarou</strong> &amp; <strong>Super Awesome Cool Pottery</strong> project</p>\n  </footer>\n</div>	{}	Registry tenant landing page for Jordan (art teacher) user journey	2026-11-25 01:24:19.902737+00	2026-11-25 01:24:20.13582+00
\.


--
-- Data for Name: tenant_domains; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.tenant_domains (id, tenant_id, domain, status, is_primary, render_domain_id, verification_error, verified_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: tenant_profiles; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.tenant_profiles (tenant_id, description, created_at, billing_email, billing_phone, billing_address, organization_type) FROM stdin;
\.


--
-- Data for Name: tenant_users; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.tenant_users (tenant_id, user_id, is_primary, created_at, role) FROM stdin;
00000000-0000-0000-0000-000000000000	c4235af3-a14c-4e9b-b09b-4b2986509a15	t	2026-11-25 01:24:21.249365+00	admin
\.


--
-- Data for Name: tenants; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.tenants (id, name, slug, created_at, stripe_customer_id, stripe_subscription_id, billing_status, trial_ends_at, subscription_started_at, canonical_domain, magic_link_expiry_hours, stripe_connect_account_id, stripe_charges_enabled, stripe_details_submitted, created_from_ip) FROM stdin;
00000000-0000-0000-0000-000000000000	Registry Platform	registry	2026-11-25 01:24:18.67472+00	\N	\N	active	\N	\N	\N	1	\N	f	f	\N
\.


--
-- Data for Name: transfer_requests; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.transfer_requests (id, enrollment_id, target_session_id, requested_by, reason, status, admin_notes, processed_by, processed_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: user_preferences; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.user_preferences (id, user_id, preference_key, preference_value, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: user_profiles; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.user_profiles (user_id, email, name, phone, data, created_at) FROM stdin;
68d63719-0351-4184-9607-434b9fbe52b1	system@tinyartempire.com	System	\N	\N	2026-11-25 01:24:19.794604+00
c4235af3-a14c-4e9b-b09b-4b2986509a15	admin@registry.platform	Platform Admin	\N	\N	2026-11-25 01:24:21.249365+00
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.users (id, username, passhash, created_at, birth_date, user_type, grade, email_verified_at, invite_pending, deactivated_at) FROM stdin;
68d63719-0351-4184-9607-434b9fbe52b1	system	nologin	2026-11-25 01:24:19.793643+00	\N	parent	\N	\N	f	\N
c4235af3-a14c-4e9b-b09b-4b2986509a15	platform_admin	$2b$12$DummyHashForSystemUser	2026-11-25 01:24:21.249365+00	\N	admin	\N	\N	f	\N
\.


--
-- Data for Name: waitlist; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.waitlist (id, session_id, location_id, student_id, parent_id, "position", status, offered_at, expires_at, notes, created_at, updated_at, family_member_id) FROM stdin;
\.


--
-- Data for Name: webhook_events; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.webhook_events (id, stripe_event_id, event_type, received_at, processed_at, account, tenant_id, payload) FROM stdin;
\.


--
-- Data for Name: workflow_runs; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.workflow_runs (id, workflow_id, latest_step_id, continuation_id, user_id, data, created_at) FROM stdin;
\.


--
-- Data for Name: workflow_steps; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.workflow_steps (id, slug, description, workflow_id, template_id, metadata, depends_on, created_at, updated_at, class, outcome_definition_id, label) FROM stdin;
\.


--
-- Data for Name: workflows; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.workflows (id, slug, name, description, first_step, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: changes; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.changes (change_id, script_hash, change, project, note, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
c9235c00bc368836d5323cd4b98cadfa673aa00e	a363697ff7f1f2ad0642dfc426f003e430fbb342	users	registry	initial creation of users table and basic schema etc	2026-11-25 01:24:14.968208+00	root	root@vm	2024-05-13 17:21:58+00	Chris Prather	chris@prather.org
2960f6c6a1df94ef7f1c75a036db14aefe121bc5	978d2b0afaad7749217fc4bf998d858c91cb9e93	workflows	registry	add workflows\n\nWorkflows define a sequence of steps to be executed. We process each step and record the outcome in a workflow run.	2026-11-25 01:24:15.077816+00	root	root@vm	2024-05-13 17:30:35+00	Chris Prather	chris@prather.org
2abd1a15dc06e9db731062527f8541e8c79ffb6f	24d73f7d6572fe110f256ca48b0a2a48dfafa96b	tenant-on-boarding	registry	create an onboarding workflow for tenants	2026-11-25 01:24:15.174332+00	root	root@vm	2024-05-20 21:00:32+00	Chris Prather	chris@prather.org
2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c	707b1c42fa45736727df395e145cbf439387c241	schema-based-multitennancy	registry	add the tools to do the schema-based multi-tenancy	2026-11-25 01:24:15.256275+00	root	root@vm	2024-05-21 01:43:52+00	Chris Prather	chris@prather.org
5920ebcdc5fd6c9478af9fb1e435aedd26b5b5ce	3020bd64a1a510456cf157551ff7d475b0f916ef	events-and-sessions	registry	Add events and sessions to the system	2026-11-25 01:24:15.390596+00	root	root@vm	2024-05-31 03:36:11+00	Chris Prather	chris.prather@tamarou.com
72bea40753b0250624322f67c9a64fe479f02df7	67a0442cd1589b353394cbd451cca098bb8e8634	edit-template-workflow	registry	default workflow for editing templates	2026-11-25 01:24:15.489498+00	root	root@vm	2025-02-11 23:59:19+00	Chris Prather	chris.prather@tamarou.com
daf665c0e9b4b1255a0cf09bb88e322f6609b59f	db62b982c609c21307787f014f58577662cca0cd	outcomes	registry	add outcome definitions	2026-11-25 01:24:15.628061+00	root	root@vm	2025-02-21 06:45:47+00	Chris Prather	chris.prather@tamarou.com
c0bb268a4a0c27a97351166c95d50a5f6d73d0ae	7d3e7133c01ac03e83020ba1578259ec444584cd	summer-camp-module	registry	add summer-camp-module	2026-11-25 01:24:15.740592+00	root	root@vm	2025-02-22 04:38:37+00	Chris Prather	chris.prather@tamarou.com
6d1c676dccf7787d99a54edd3ec556193ff0562d	464a90d2ef6e7939e38fa2717439f3796e2f6936	fix-tenant-workflows	registry	Fix tenant workflows to include first_step	2026-11-25 01:24:15.862381+00	root	root@vm	2025-03-22 18:57:13+00	Chris Prather	chris.prather@tamarou.com
4d1cce9dd15eadfe664b1a909c36f1afd6d943f2	7851550d6b87474630cd02469c9772024987ce32	program-types	registry	Add program types configuration system	2026-11-25 01:24:16.015114+00	root	root@vm	2025-01-27 12:00:00+00	Claude	noreply@anthropic.com
ac009951a991475b6b82050987874c5e1562b227	e79fc2deea1f57838d388bd3effc672f3d9de20b	enhanced-pricing-model	registry	Transform pricing to flexible pricing_plans with multiple tiers per session	2026-11-25 01:24:16.108423+00	root	root@vm	2025-01-27 12:30:00+00	Claude	noreply@anthropic.com
ca85da23e2f52eb6ef3b500530d301617d8d64d3	6e636122ad2b14731a616bee3fb8d06083559358	attendance-tracking	registry	Add attendance tracking infrastructure	2026-11-25 01:24:16.21318+00	root	root@vm	2025-01-27 13:00:00+00	Claude	noreply@anthropic.com
9478a08db15d08f6fae783493e14eb2348a478a4	1b0a9ae93451b1aad3fcad727c30430146b39669	waitlist-management	registry	Add waitlist functionality to enrollment system	2026-11-25 01:24:16.326843+00	root	root@vm	2025-01-27 13:30:00+00	Claude	noreply@anthropic.com
125881c219bfb9b9053e66b6b5fb5fdb720a1ee3	fa279aaea8c8f5c6fc0fc942ac69274ced15c1d4	add-program-type-to-projects	registry	Add program type reference to projects	2026-11-25 01:24:16.420922+00	root	root@vm	2025-01-27 14:00:00+00	Claude	noreply@anthropic.com
b935f44f3eace95edc2fa318ed7de32c27e8ac1a	b93b975d490c4384a02a3f8a66a48d99fd35a84b	add-user-fields-for-family	registry	Add birth_date, user_type, grade fields to users	2026-11-25 01:24:16.503412+00	root	root@vm	2025-01-27 14:25:00+00	Claude	noreply@anthropic.com
7deaa9fb9f8f3d0309d635af087792c28525f78e	189953a84a37895f33e367d8eb0fe3b647a2bfdf	multi-child-data-model	registry	Add family_members table for multi-child support	2026-11-25 01:24:16.601238+00	root	root@vm	2025-01-27 14:30:00+00	Claude	noreply@anthropic.com
815c14422aeab29c0c21415ea7e8927785a1c910	36fd27b0aff2c634ec86eb7662a0ecbc11d188e6	payments	registry	Add payments infrastructure for Stripe integration	2026-11-25 01:24:16.728665+00	root	root@vm	2025-01-27 19:00:00+00	Claude	noreply@anthropic.com
eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6	344a280c4b37d460e57e312c538aa0507dae53e1	add-payment-to-enrollments	registry	Add payment_id reference to enrollments table	2026-11-25 01:24:16.884308+00	root	root@vm	2025-01-27 19:15:00+00	Claude	noreply@anthropic.com
acd808bf85b5a9d8971f598186ced619196ffd0e	8cdbcbf5f5d6b5933c1027b75293e23c21f82f45	notifications-and-preferences	registry	Add notifications and user preferences for attendance tracking	2026-11-25 01:24:17.062208+00	root	root@vm	2025-01-28 10:00:00+00	Claude	noreply@anthropic.com
5ce709b8eff5b3b920e7a675d78bee9dabd98367	9f6bfbd59ca138c524285ed7d9f0b7895354f801	parent-communication-system	registry	Add parent communication system with messages, recipients, and templates	2026-11-25 01:24:17.203304+00	root	root@vm	2025-01-28 11:00:00+00	Claude	noreply@anthropic.com
fbe73787977942423bb4d7ba5dd152c0c1551e38	fea7e5a85e605358de32808abb27b09f7dd78e83	performance-optimization	registry	Add database indexes and performance optimizations for production readiness	2026-11-25 01:24:17.346309+00	root	root@vm	2025-01-28 15:00:00+00	Claude	noreply@anthropic.com
d7d8aaecb2610865fd3801bb68ef57e474b29181	4a0067318476e1aa7150a0f54458884434cf9bfb	stripe-subscription-integration	registry	Add Stripe subscription integration for tenant billing	2026-11-25 01:24:17.459955+00	root	root@vm	2025-01-28 16:00:00+00	Claude	noreply@anthropic.com
8eb88eeec3cb411430882061df8d5563af64ba1c	3fa34c99f03fa41b55239b2a0c7f393ba3d49bbf	fix-multi-child-enrollments	registry	Fix multi-child enrollment constraints for cleaner architecture	2026-11-25 01:24:17.570619+00	root	root@vm	2025-07-15 00:34:24+00	Chris Prather	chris.prather@tamarou.com
4883848eccc158220c9e751882d20ae963d71f52	c4e3ea6ffbffc982060b0d165f60f0ff17bf78e7	flexible-enrollment-architecture	registry	Create flexible enrollment architecture supporting family, individual, group, and corporate students	2026-11-25 01:24:17.731419+00	root	root@vm	2025-07-15 01:09:59+00	Chris Prather	chris.prather@tamarou.com
f6dbddd094284b0b7296c6e8258922882ae24b5d	b5baa9d2cf71178ed6fd3382231eb69d0b310cfd	remove-student-id-foreign-key	registry	Remove student_id foreign key constraint to support polymorphic student references	2026-11-25 01:24:17.824972+00	root	root@vm	2025-07-15 01:28:59+00	Chris Prather	chris.prather@tamarou.com
ffe9a13ee38d1ffa2c706750718b34126adfe6e1	d2feca17971e5f93417b098a4295ff70ead570ee	fix-waitlist-family-member-refs	registry	Fix waitlist student_id to reference family_members instead of users	2026-11-25 01:24:17.903465+00	root	root@vm	2025-07-16 14:30:00+00	Claude	noreply@anthropic.com
3c3d83d65febc9de2fbce70f02fa01b5483736e8	49be975f75b20172863921261abf3906bc100990	fix-waitlist-reorder	registry	Fix waitlist position reordering to avoid unique constraint violations	2026-11-25 01:24:17.986973+00	root	root@vm	2025-07-16 12:30:00+00	Claude	noreply@anthropic.com
300e4d9f1d6bafe1b45f937ea482260f3313760d	b2b54846389dbdf3e2cf7ecbb15ae53fb4175d82	fix-waitlist-reorder-v2	registry	Improved waitlist position reordering to fully avoid constraint violations	2026-11-25 01:24:18.101133+00	root	root@vm	2025-07-16 22:50:00+00	Claude	noreply@anthropic.com
0903ffab54af2242711b1cb470a44753acf6c9d7	695f0a352ff02e4b5f84381856fe538ac1badbb7	fix-waitlist-reorder-v3	registry	Remove problematic database trigger and handle position reordering in application code	2026-11-25 01:24:18.216686+00	root	root@vm	2025-07-17 00:00:00+00	Claude	noreply@anthropic.com
acbd53f8d5ddfc205c3c1ca518ed92170803e32c	7b6df5319ffd75e81b5f3f06e95102a1df7f2e92	drop-transfer-business-rules	registry	Add drop and transfer business rules with admin approval workflow	2026-11-25 01:24:18.338081+00	root	root@vm	2025-09-18 00:00:00+00	Claude	noreply@anthropic.com
41ae5ed8ebd0150b8a8c2987bdbfd98967252b18	4ca09b1d82b01de2a829979849fa4a7f4c3120d4	remove-waitlist-position-constraint	registry	Remove unique constraint on waitlist position to allow status-based visibility	2026-11-25 01:24:18.428823+00	root	root@vm	2025-09-21 00:00:00+00	Claude	noreply@anthropic.com
788f8edbabafb05aef3b90f4b634beb1aaab7b8b	7dda1d870afb87ee03300b43bacf070e53c5c5ba	installment-payment-schedules	registry	Add payment schedules and scheduled payments for installment processing	2026-11-25 01:24:18.536423+00	root	root@vm	2025-09-23 03:35:05+00	Chris Prather	chris.prather@tamarou.com
2fc34cc17316d64ee48ef1c04e4d9c5e096b29ba	e7ea8e7d72a0222c7493190abb060dd0767adb28	simplify-installment-schema-for-stripe	registry	Simplify database schema to use Stripe native scheduling and retry features	2026-11-25 01:24:18.63129+00	root	root@vm	2025-09-24 18:00:00+00	Claude	noreply@anthropic.com
f61a99336db06d9d07bd30abcf6e18e98d7609ac	0f1e40107de5540b06f5181f72d75c6741728143	unified-pricing-infrastructure	registry	Add unified tenant-to-tenant pricing infrastructure	2026-11-25 01:24:18.775722+00	root	root@vm	2025-09-29 00:44:03+00	Chris Prather	chris.prather@tamarou.com
eb5973974d4f4c06b6e5a93c84b5a66bfcd8f342	031717d9b7ea0651ef6b5f67942c8c978f502dbe	consolidate-pricing-relationships	registry	Consolidate pricing relationships into unified model	2026-11-25 01:24:18.929232+00	root	root@vm	2025-09-29 16:07:15+00	Chris Prather	chris.prather@tamarou.com
20f187ed4e2e4c35404fcb5f7d48df933cebfcd5	6017815b229c39d2e9f7af54f1a963e3257a5bf2	pricing-relationship-events	registry	Add event sourcing for pricing relationship audit trail	2026-11-25 01:24:19.066049+00	root	root@vm	2025-09-29 19:55:59+00	Chris Prather	chris.prather@tamarou.com
5f3d84a4d2158ce0ffcfeabc5772970faca7c3d3	f41063facc70f0ff67e7cc54de594af5b99d358b	remove-pricing-plan-relationship-fields	registry	Remove obsolete target_tenant_id and offering_tenant_id from pricing_plans	2026-11-25 01:24:19.15376+00	root	root@vm	2025-09-29 22:27:51+00	Chris Prather	chris.prather@tamarou.com
a2248de7c1f81778ea19e6f9bc5c94e806e21268	5c6daf2fa1ab2205c6f0f0a0b153947e9304f3bd	passwordless-auth	registry	Passwordless auth: passkeys, magic links, API keys	2026-11-25 01:24:19.266628+00	root	root@vm	2026-03-25 00:00:00+00	Chris Prather	chris.prather@tamarou.com
afdf73989587e92e423e0b5f643361890a90a860	bdd207b58bea14042c69ffad9efcc71e3cbfbcd7	auth-notification-types	registry	Add auth notification types to notification_type enum	2026-11-25 01:24:19.361468+00	root	root@vm	2026-03-30 06:56:54+00	Chris Prather	chris.prather@tamarou.com
c0834addb5a970c41dc185be91f226cba562e013	314f27eca2ee77ce95e888776a12618b7d1bb0fc	tenant-domains	registry	Custom domain management for tenants	2026-11-25 01:24:19.483469+00	root	root@vm	2026-03-30 19:04:42+00	Chris Prather	chris.prather@tamarou.com
5656344b5447eb9e8d5b274f18d9fbfffa20f8d4	aeab9e685093de23275127520d1387c90bff2e78	magic-link-verification	registry	Add verified_at column for two-step magic link flow	2026-11-25 01:24:19.571451+00	root	root@vm	2026-03-31 12:11:05+00	Chris Prather	chris.prather@tamarou.com
c3c7ae6599f4db30315a79d7021519f29dafa31d	ca3c13270b018c747b12a06b702742a416a46a0e	waitlist-accepted-status	registry	Add accepted status to waitlist check constraint	2026-11-25 01:24:19.66648+00	root	root@vm	2026-04-05 01:37:21+00	Chris Prather	chris.prather@tamarou.com
b1024a8fd0df88c3fd8a543fb5a09512b3fa1cfb	a54ac0d95185ebb088b7bc391c48cb9cfbfb792e	seed-registry-storefront	registry	Seed registry tenant storefront (empty stub, deployed to production)	2026-11-25 01:24:19.755992+00	root	root@vm	2026-04-07 13:42:30+00	Chris Prather	chris.prather@tamarou.com
0d0c296e547099f9f75884c8283a0077920abc8c	70ca373942437f7f4629b935d4f21ac4b07c0c2e	seed-registry-storefront-v2	registry	Seed registry tenant storefront with actual data	2026-11-25 01:24:19.851502+00	root	root@vm	2026-04-07 14:44:00+00	Chris Prather	chris.prather@tamarou.com
3c41efd35c15d993a9e2b9e7621c7f14de92649e	a27a8dd63d8941cf02199a86b6f9115998857b58	registry-landing-page-template	registry	Customize registry tenant landing page for Jordan's user journey	2026-11-25 01:24:19.953578+00	root	root@vm	2026-04-11 00:00:00+00	Chris Prather	chris.prather@tamarou.com
730dfd28d76922a358dc3e5eaeb144725df7111e	526f15f28e63d0a77f4806b4d3b7aa513564d281	fix-utf8-mojibake	registry	Delete DB templates with mojibake so app reimports fixed versions	2026-11-25 01:24:20.059844+00	root	root@vm	2026-04-11 12:00:00+00	Chris Prather	chris.prather@tamarou.com
4a34ed08664b5ae39f7caacd4f663285efb88267	819d7e62eb2165db006a8d41131c2cfaa0ab9f00	update-registry-landing-copy	registry	Update registry landing page copy and 3x2 card grid	2026-11-25 01:24:20.185199+00	root	root@vm	2026-04-11 14:00:00+00	Chris Prather	chris.prather@tamarou.com
44c65bead55e0a35c5372aa2410a7fe5b3bf0e6b	83f48bc9c421c0e1cf1f0825a2e6a9498ca63e0d	program-publish-status	registry	Add status to projects and contact_person_id to locations for admin program setup	2026-11-25 01:24:20.313501+00	root	root@vm	2026-04-19 00:00:00+00	Chris Prather	chris.prather@tamarou.com
c2d827c1542f2cf88b9769412919a1ee176147e7	3e1b6a2bee1de37a32150e01a522d5d6ed4caa09	enrollment-confirmation-notification-type	registry	Add enrollment_confirmation notification type	2026-11-25 01:24:20.410831+00	root	root@vm	2026-04-23 00:00:00+00	Chris Prather	chris.prather@tamarou.com
d8dd117aea69688b601f189b8a05f2cc9975b897	8c6355a7f1a9332e26a6d5cc6b845776838157c7	webhook-event-dedup	registry	Track processed Stripe webhook event IDs for deduplication	2026-11-25 01:24:20.541969+00	root	root@vm	2026-06-01 00:00:00+00	Chris Prather	chris.prather@tamarou.com
bfb052f4957649f0ccf5c59096ee321a100f2886	aa1d00cc663322063dd336e664e72e0f60d56910	enrollment-payment-dedup	registry	Unique index to make paid-enrollment finalization idempotent	2026-11-25 01:24:20.647094+00	root	root@vm	2026-06-01 01:00:00+00	Chris Prather	chris.prather@tamarou.com
e9ff0519934e4fcea62f4734c5b9d3b20c09ef4c	8951d1778d26f1f372e59ee27de44183a0470533	fix-attendance-student-id-fkey	registry	Remove student_id FK from attendance_records to allow polymorphic family_member references	2026-11-25 01:24:20.808689+00	root	root@vm	2026-06-08 00:00:00+00	Chris Prather	chris.prather@tamarou.com
3c299ff8324976d192be357e48699e64c975784f	5b0df8b63eb927e6f21cec635192008cda10414e	fix-clone-schema-identifier-quoting	registry	Quote dest_schema consistently with quote_ident in clone_schema to support reserved-word schema names	2026-11-25 01:24:20.895299+00	root	root@vm	2026-06-10 00:00:00+00	Chris Prather	chris.prather@tamarou.com
3207dcbdd391a3113f62367a901b0319137093bc	4aa621090f6b0cab6de2d09acb81779587e32827	tenant-stripe-connect	registry	Add per-tenant Stripe Connect account and readiness flags for destination charges	2026-11-25 01:24:20.984132+00	root	root@vm	2026-06-10 00:00:00+00	Chris Prather	chris.prather@tamarou.com
28e0bf2c6d92e23110f116d7ec4bd11d3a37c607	e1650770850473953cf5a6b823e1218eb79898a0	tenant-scoped-payments	registry	Move payment tables into tenant schemas and repoint enrollments.payment_id FK for tenant-local payment isolation	2026-11-25 01:24:21.088027+00	root	root@vm	2026-06-10 00:00:00+00	Chris Prather	chris.prather@tamarou.com
28d74506683168469a7f47f7ba0500804400ebeb	2f7b7598efa787ec0a430cca91477d7261b9414f	seed-free-platform-plan	registry	Seed platform-scope Free (0%) fallback plan	2026-11-25 01:24:21.196223+00	root	root@vm	2026-06-13 00:00:00+00	Chris Prather	chris.prather@tamarou.com
ab661862f6c5f4126610587fd3e7da46123c2f04	0660243596d8771fa9e2afcefbee446c73cf1cc6	create-default-pricing-relationships	registry	Create active platform relationships so tenant plans are selectable	2026-11-25 01:24:21.315679+00	root	root@vm	2026-06-13 00:00:00+00	Chris Prather	chris.prather@tamarou.com
a3a7d4de067885cf24f3b965cee829661b4e7c63	155381d51a2aa54184c5a14f38a58449f288d20c	tenant-platform-pricing-plan	registry	Add tenants.platform_pricing_plan_id FK and backfill existing tenants	2026-11-25 01:24:21.447019+00	root	root@vm	2026-06-16 00:00:00+00	Chris Prather	chris.prather@tamarou.com
4f5c0e1ad6352f2a79bd35ab6532bea463f381dc	742ee7a544d54b7c6d9052e7ffbf2fe7022b38dd	refund-application-fee-config	registry	Declare refund_application_fee on seeded platform + tenant plans	2026-11-25 01:24:21.550366+00	root	root@vm	2026-07-03 23:09:47+00	Chris Prather	chris.prather@tamarou.com
f2e5326eff1970535911be0d1222e035d521c000	82e0ce0ff7efe488352cae133cbe6d6f7725993d	suspend-rateless-tenant-plans	registry	Stop offering tenant plans with no resolvable revenue-share rate	2026-11-25 01:24:21.692995+00	root	root@vm	2026-08-03 23:18:43+00	Chris Prather	chris.prather@tamarou.com
0efcbdec112780d02871150d379f0e2b07264241	41842368d11c145c5430b6507668c56cb17014b7	pricing-plans-amount-cents	registry	Store pricing_plans money as integer cents; the rate lives only in pricing_configuration	2026-11-25 01:24:21.807731+00	root	root@vm	2026-08-06 00:00:00+00	Chris Prather	chris.prather@tamarou.com
d685f3eb74071b32ce295c7722ef57a33c66f5d5	bf42fde8d39cdadb38af50afa9b589bd1e036804	payments-amount-cents	registry	Store payments and payment_items money as integer cents	2026-11-25 01:24:21.927606+00	root	root@vm	2026-08-06 12:00:00+00	Chris Prather	chris.prather@tamarou.com
723b2c3e0164207d1f004b5584857c3f892cb0cc	0e5f13b006f2d71bff25eca81cecded06fe708b0	schedule-amounts-cents	registry	Store installment schedule money as integer cents	2026-11-25 01:24:22.070576+00	root	root@vm	2026-08-06 13:00:00+00	Chris Prather	chris.prather@tamarou.com
7299cb40a004b6904fadeecd2da45cb01f18da03	892f9c723523cda0a17dcb6f9fa3bfa143a12d87	refund-amounts-cents	registry	Store refund money as integer cents	2026-11-25 01:24:22.214337+00	root	root@vm	2026-08-06 14:00:00+00	Chris Prather	chris.prather@tamarou.com
1e944e76794f6455bcc241ac32a0cf7ad80786f0	483666918399420d0bbfee4a43e8deb77d5252f2	drop-installment-schedules	registry	Drop the installment schedule tables from registry and every tenant schema	2026-11-25 01:24:22.305681+00	root	root@vm	2026-08-13 13:50:16+00	Chris Prather	chris.prather@tamarou.com
124e93eb6de0fd73c5506f9d21d246c748f42f60	9591878e59201ab231ca064b0d779101c4a73e91	retire-registry-plus-plan	registry	Stop offering the seeded Registry Plus hybrid plan	2026-11-25 01:24:22.413797+00	root	root@vm	2026-08-13 14:37:13+00	Chris Prather	chris.prather@tamarou.com
51493d6426abe6800146664a09dd14c4845ef24c	4fabd2002bc65abf6f175b4f55da593797e00fb6	webhook-events-processed-at	registry	Add processed_at to registry.webhook_events for received-to-processed latency	2026-11-25 01:24:22.51844+00	root	root@vm	2026-08-15 14:37:28+00	Chris Prather	chris.prather@tamarou.com
38dbe5f9ef7655079f93ab63a547b6ae7ea6c022	a6066943256c26ecb505ae52cc54919030e8534d	payments-typed-obligation	registry	Typed columns for the capacity-refund obligation, and a CHECK on payments.status	2026-11-25 01:24:22.663898+00	root	root@vm	2026-08-22 23:30:00+00	Chris Prather	chris.prather@tamarou.com
cd225459045762634487962815fd105ace1caf30	d693d33b9dab7f8231ffe47cb365268b54d159ef	enrollment-reenrol-after-drop	registry	A cancelled enrollment stops occupying its seat, so a dropped child can re-join	2026-11-25 01:24:22.781695+00	root	root@vm	2026-08-26 22:00:00+00	Chris Prather	chris.prather@tamarou.com
4f4968a7059d18a3163416e0754cd69981058282	9924e24152ed3c4b860e21f4cadb23f5d91d8e35	set-launch-revenue-share-rate	registry	Move the offered revenue-share plan to the launch rate and mark it as the launch plan	2026-11-25 01:24:22.887469+00	root	root@vm	2026-09-04 14:50:00+00	Chris Prather	chris.prather@tamarou.com
49f1934e333630282a31ceaf6eeb71898b27d9c5	e6fb13e011417f470d6d4ee424ba9bfb6ddf0fa5	seed-tier-pricing-options	registry	Put the Solo/Studio/Empire tier model into the plans the signup page renders	2026-11-25 01:24:22.986258+00	root	root@vm	2026-09-04 16:05:00+00	Chris Prather	chris.prather@tamarou.com
0f7d16835c8b41ad227ab66d68c36003de68fc21	19f7d9dbbb4d29ecfc81ee77d521b8b57f801d5f	clear-template-import-stamps	registry	Drop stamps computed from bytes so the fixed character-based import re-stamps every row	2026-11-25 01:24:23.103428+00	root	root@vm	2026-09-13 21:15:00+00	Chris Prather	chris.prather@tamarou.com
20680f8b72d460b535289c226047d46b15a1a499	168162a565c0683a207bd496b7098582d120d22b	tenant-slug-lowercase	registry	Tenant slugs must be lowercase: clone_schema case-folds an unquoted dest_schema	2026-11-25 01:24:23.209793+00	root	root@vm	2026-09-14 04:05:00+00	Chris Prather	chris.prather@tamarou.com
a7040f956947ab1eaa9b1eb52dac77c768d24082	b954ff9b2c773c4b94766e46b4c7867c62fb2ab6	session-waitlist-toggle	registry	A session can turn its waitlist off, so a full one is simply full	2026-11-25 01:24:23.322959+00	root	root@vm	2026-09-24 12:10:00+00	Chris Prather	chris.prather@tamarou.com
2a46bba61658475c68afeeaf8a8333220197df38	e12fab7b39c35cd9c3740e9e177858d2412a0632	pricing-plan-versions	registry	Pricing plans become append-only versions, and a charge records the version it used	2026-11-25 01:24:23.446059+00	root	root@vm	2026-09-26 19:20:00+00	Chris Prather	chris.prather@tamarou.com
e5488490cd4c51eeff34b23533b1a576214ba3dc	7e188e2af6ae740b521a797f7c9874fb12c957d1	user-deactivation	registry	A departed staff member can be deactivated, which revokes every way in	2026-11-25 01:24:23.581754+00	root	root@vm	2026-09-27 15:30:00+00	Chris Prather	chris.prather@tamarou.com
3b44ac15d9b45f35b00f7fdcb7bc0455f131f2de	2545a59d5d8631265f410068732e1784bf5e5003	tenant-signup-drop-plan-page	registry	Signup stops asking which plan: everyone starts on the one tier that is on sale	2026-11-25 01:24:23.674495+00	root	root@vm	2026-09-28 17:45:00+00	Chris Prather	chris.prather@tamarou.com
5f054736a12b03dd860447d9c5aa4354124fa7fc	b2d61546b298825409fb563ca6703acefcd64f4f	tenant-created-from-ip	registry	Record which address provisioned a tenant, so the clone cost can be bounded	2026-11-25 01:24:23.802375+00	root	root@vm	2026-09-28 23:20:00+00	Chris Prather	chris.prather@tamarou.com
a985ade9d594ea8f7f23d090f87782247ab35b1a	8ffa4bff43425fec72bd6fd38d6bb70425b89f1b	instalments-declared-in-configuration	registry	An instalment offer becomes a declared shape rather than a boolean and a count	2026-11-25 01:24:23.930562+00	root	root@vm	2026-09-29 17:55:00+00	Chris Prather	chris.prather@tamarou.com
8b18333bb7b02f9e0b7b8bd9a06119c2bdae7f29	3e2c7d9745770f77757b455a88ec99c4e9f60b96	payments-carry-instalments	registry	A payment can be one instalment of several, recorded at enrolment rather than derived from Stripe	2026-11-25 01:24:24.054935+00	root	root@vm	2026-09-29 19:40:00+00	Chris Prather	chris.prather@tamarou.com
482b7ffee557fb56a318a238cad5bfa863c3ebd3	029ad6f760c9a2dca55b55da29fab103fe7f480c	platform-settings	registry	Platform configuration Alex can see and change without a deploy	2026-11-25 01:24:24.162097+00	root	root@vm	2026-09-30 15:45:00+00	Chris Prather	chris.prather@tamarou.com
0b109058cb119603bba20014e1c322f8cdbb41bd	930660ff8c37f61d4cfb9513c59fe7b37c799105	magic-link-expiry-one-hour	registry	A magic link lasts an hour rather than a day	2026-11-25 01:24:24.282289+00	root	root@vm	2026-10-03 00:30:00+00	Chris Prather	chris.prather@tamarou.com
9226348ab8a8de0a5d645aab5a60e085d9e5603e	46f6591370f3bd1deae323a9aaf2513921692bbf	payments-record-platform-fee	registry	Record what the platform took on a charge, and the plan version it took it under	2026-11-25 01:24:24.381317+00	root	root@vm	2026-10-05 18:00:00+00	Chris Prather	chris.prather@tamarou.com
36339a19600bb0603d8b549e379a84d2f4c31770	55639760aae3dd8c687dc961cf161b3a5ff87ae3	waitlist-joined-notification-type	registry	A parent who joins a waitlist gets it in writing	2026-11-25 01:24:24.490802+00	root	root@vm	2026-10-08 17:30:00+00	Chris Prather	chris.prather@tamarou.com
4b26e805ef3f76017e8e2f48bb26f096032c5544	e7cfdc953acc75ede33464c31ca4967fd09beca8	domain-notification-types	registry	A tenant hears the outcome of domain verification	2026-11-25 01:24:24.603594+00	root	root@vm	2026-10-10 14:00:00+00	Chris Prather	chris.prather@tamarou.com
003b7c0f8200f5fd1ec223e09741654ae9662a4a	cd5862a2e613bd8cc84ad4f5c2d2fda728dbdb7b	send-cap-setting	registry	The unverified-tenant send cap is a row Alex can change	2026-11-25 01:24:24.704306+00	root	root@vm	2026-10-10 19:30:00+00	Chris Prather	chris.prather@tamarou.com
9d8ffe01420a63c9d947f43cfd750757da3dcb62	f0688e40e7b42210bd73805592617b5a387074a2	workflow-step-label	registry	A workflow step has a name a person can read, beside the note for developers	2026-11-25 01:24:24.808414+00	root	root@vm	2026-10-13 16:10:00+00	Chris Prather	chris.prather@tamarou.com
61e86b5860902410a8a28e1a212b299689d11a00	85cbc4fff6fea29cf38f30c7041578952dbb3f19	collapse-platform-tenant	registry	The platform is one tenant row: the all-zeros row, slug registry	2026-11-25 01:24:24.929356+00	root	root@vm	2026-11-23 12:00:00+00	Chris Prather	chris.prather@tamarou.com
f4e3c4f22d425732fcbe9751b2cc4f11b83c9b0a	f99fe69ed6827e388fe5b7aaf6812c5dd8770051	tenant-users-role	registry	A membership carries its own role, so authority is read per tenant	2026-11-25 01:24:25.031509+00	root	root@vm	2026-11-23 18:00:00+00	Chris Prather	chris.prather@tamarou.com
b6a2f0778c5f1b8c4f45841129ee9a2d52a1e91a	13f95cc3fda3cbb7fe88c72ede391fbe03250b13	platform-tenant-unlinks-solo	registry	The platform takes no share of its own sales	2026-11-25 01:24:25.138017+00	root	root@vm	2026-11-23 20:00:00+00	Chris Prather	chris.prather@tamarou.com
ca6fec4debbcbf8af172ae04d882036c4b0d132a	f2db380186128185c26aba247c34995675e9a06b	operator-right	registry	The platform tenant holds the operator right as seeded data	2026-11-25 01:24:25.24296+00	root	root@vm	2026-11-23 22:00:00+00	Chris Prather	chris.prather@tamarou.com
98439380cc75400ca65bc48ee27e7f19a20981df	d4aa7bb524027066e63c138be712ae081d03ddcc	waitlist-offer-notification-types	registry	A parent who opted in hears about a waitlist offer and its expiry	2026-11-25 01:24:25.352193+00	root	root@vm	2026-11-23 23:00:00+00	Chris Prather	chris.prather@tamarou.com
bea3ff7c2f9ee2383a93a41094664bc77bc8e1d7	4ebbed270385b6930ffe021dea847db44faee19a	tenant-stripe-account-unique	registry	A Stripe account id belongs to one tenant at most	2026-11-25 01:24:25.47304+00	root	root@vm	2026-11-24 00:00:00+00	Chris Prather	chris.prather@tamarou.com
e8b8d42aaf2238ce300b9a8934a881ddf24eeeb1	e9ce1ca6bd4e067f173f9f53ae11277165683fcc	webhook-events-connect-payload	registry	Store refund, dispute and customer events from the Connect endpoint for later	2026-11-25 01:24:25.597261+00	root	root@vm	2026-11-24 01:00:00+00	Chris Prather	chris.prather@tamarou.com
a672b8f94e5d63882b800757856c05f9cd461fec	d280fdb7ca1ff91940044af5d86ace0afa4365fd	pricing-plan-rate-check	registry	A plan rate written in SQL is held to the rule PricingPlan->create enforces	2026-11-25 01:24:25.743448+00	root	root@vm	2026-11-24 02:00:00+00	Chris Prather	chris.prather@tamarou.com
47c63377bec3e8cbec9e1027d6b00ebefef03401	539f4b536695d7b1581ccf03e38edf7555f2a2b1	payments-platform-fee-refunded	registry	Record how much of the platform fee Stripe reports refunded	2026-11-25 01:24:25.842273+00	root	root@vm	2026-11-24 03:00:00+00	Chris Prather	chris.prather@tamarou.com
25b283927f9405f30b299027f21e58d81f242400	4ed1ab2db923466ed037b6c191900c04ce004481	tenant-plan-has-rate	registry	A tenant links only to a platform plan that carries a rate	2026-11-25 01:24:25.959409+00	root	root@vm	2026-11-24 03:30:00+00	Chris Prather	chris.prather@tamarou.com
b1afd3dadcbc64642cf1280bb90f683e3aa7e214	48f2a066ad267f31d37f8593d53d5f0864e6aa70	priceops-offer-versions	registry	Resources and offers with append-only versions, immutable once published	2026-11-25 01:24:26.157297+00	root	root@vm	2026-11-24 04:00:00+00	Chris Prather	chris.prather@tamarou.com
4693a092868c7a89538d03a8d72be9ba8a383922	28d0adf04ef910d1cdc6abf8083181fbef400e6e	priceops-offer-policies	registry	Offer versions carry price, units, payment plans, policies and conditions as data	2026-11-25 01:24:26.320886+00	root	root@vm	2026-11-24 05:00:00+00	Chris Prather	chris.prather@tamarou.com
9c29b9f3efcea6df803676964f375f39e1b2f9cb	43566c99de5d7df5d97a6558bea739c682b178ff	priceops-entitlements	registry	Entitlements record holder, payer, stamped offer version and plan, and in-effect period	2026-11-25 01:24:26.434236+00	root	root@vm	2026-11-24 06:00:00+00	Chris Prather	chris.prather@tamarou.com
44af8b065e0e4213dd2658b391307be392b6330a	d19fe4d7e1b5d37a251331a14cf825e440c4aa34	priceops-entitlement-one-phase	registry	One schedule phase of an offer in effect at a time per holder, by exclusion constraint	2026-11-25 01:24:26.619433+00	root	root@vm	2026-11-24 07:00:00+00	Chris Prather	chris.prather@tamarou.com
7aa55c6bc7e28c6e05f161d2c4b9a0297c54b97c	0562fc15b4a8d89398b694896b02e32c65e46400	priceops-entitlement-units	registry	A discrete entitlement holds named units of a finite resource, never past its capacity	2026-11-25 01:24:26.754918+00	root	root@vm	2026-11-24 07:30:00+00	Chris Prather	chris.prather@tamarou.com
f9f623bf03447c600f457a7eda26623fe0261165	87b255a8222a7df0f7ca81c80dfc7e5d99d6ac31	priceops-entitlement-lifecycle	registry	An entitlement is active or ended once, with when and why, and links to the payment that created it	2026-11-25 01:24:26.861233+00	root	root@vm	2026-11-24 08:00:00+00	Chris Prather	chris.prather@tamarou.com
f4bafd47b218c3ced235d8f4d268ac6f97e74a11	97070b035912d8bc25a735aafd92e8388fd8d92e	bootstrap-platform-offers	registry	The bootstrap seeds Solo v1 and the platform's offers to itself, with registry's entitlements	2026-11-25 01:24:26.963697+00	root	root@vm	2026-11-24 08:30:00+00	Chris Prather	chris.prather@tamarou.com
c10baef3750b3cb270c857057a98d09391b041a9	93afac3f5042c053cd653895626aee96373d3f87	priceops-occurrence-resources	registry	An occurrence is its own finite resource, and a class offer covers its class's occurrences	2026-11-25 01:24:27.075702+00	root	root@vm	2026-11-24 09:00:00+00	Chris Prather	chris.prather@tamarou.com
bc3408ec460bb93f449568284cc0d84a5f9e9ab5	25f732f2e408a21f93ffc8ada5fcfbd26bef4546	operator-right-entitlement	registry	The platform holds the operator right as an entitlement, and the interim table goes	2026-11-25 01:24:27.224067+00	root	root@vm	2026-11-24 09:30:00+00	Chris Prather	chris.prather@tamarou.com
c12f623ddfbb54d4c55ae4ec2866f0df51b710ca	ec3a93940f3905d600f569a5f411fa36cdaffbb1	self-offer-guard	registry	Only the platform tenant may hold the platform's offers to itself (holder_is_offerer)	2026-11-25 01:24:27.329331+00	root	root@vm	2026-11-24 10:00:00+00	Chris Prather	chris.prather@tamarou.com
4b0a66a2145016179573b21f17579912018052d5	ac2ddc88c594ff8397c9bb54f5f0bd5d99e6e4a7	platform-entitlement-one-in-effect	registry	A tenant holds one active platform entitlement to payment processing at a time	2026-11-25 01:24:27.426069+00	root	root@vm	2026-11-24 11:00:00+00	Chris Prather	chris.prather@tamarou.com
53fbbe230350dec54c28791a4e837b9f7cd8f792	3fa4ee189b121258e1071b6c452f4a50a746c97f	platform-entitlement-replaces-plan-link	registry	A tenant's platform fee comes from its platform entitlement, and the plan link is dropped	2026-11-25 01:24:27.544114+00	root	root@vm	2026-11-24 12:00:00+00	Chris Prather	chris.prather@tamarou.com
c64592d9d2dde57f3eec4c6ebbb3659cb063743b	73ed775c6952803f21bd0e90ca674c53ecbc852e	offer-publishing-adds-percentage-of-sales	registry	offer-publishing gains a percentage-of-sales payment step; the stored workflow is cleared so import rebuilds it	2026-11-25 01:24:27.655784+00	root	root@vm	2026-11-24 13:00:00+00	Chris Prather	chris.prather@tamarou.com
f0a4f55ba657aa26ca574bf9ba40872cf441059f	7be578d022b2680319b6dff005a9309fe8e2fd38	offer-publishing-adds-use-policy	registry	offer-publishing asks for a use policy, so the stored workflow is rebuilt from YAML	2026-11-25 01:24:27.755494+00	root	root@vm	2026-11-24 14:00:00+00	Chris Prather	chris.prather@tamarou.com
62388102bfbedfdd7640f8b026241a36b5f57ab5	ef6dffd671ef5d85e91a5dd4259d9667ef2a72b5	offer-publishing-adds-resource-step	registry	offer-publishing starts at a resource step, so the stored workflow is cleared for re-import	2026-11-25 01:24:27.86927+00	root	root@vm	2026-11-24 15:00:00+00	Chris Prather	chris.prather@tamarou.com
73a3d860a6912b73de7c53a9a01b84d88cb98c6f	831d2b69052857ade91c808b407eb3db9c5afa48	offer-publishing-adds-refund-policy	registry	offer-publishing asks for a refund policy at its own step, so the stored workflow is rebuilt from YAML	2026-11-25 01:24:27.988792+00	root	root@vm	2026-11-24 16:00:00+00	Chris Prather	chris.prather@tamarou.com
d8a9b842a07bd75be465900ed0d5bb00f05a2fde	5facc90472dbed22d12feb3da1ec2de9e9ac1f5a	offer-publishing-adds-change-policy	registry	offer-publishing asks for a change policy, so the stored workflow is rebuilt from YAML	2026-11-25 01:24:28.104687+00	root	root@vm	2026-11-24 17:00:00+00	Chris Prather	chris.prather@tamarou.com
48de20285d571433867e32335386b105696fba0e	44836d16a17f8cb536ef01cbb1514525de84925f	offer-publishing-adds-expiry-policy	registry	offer-publishing asks for an expiry policy, so the stored workflow is rebuilt from YAML	2026-11-25 01:24:28.211967+00	root	root@vm	2026-11-24 18:00:00+00	Chris Prather	chris.prather@tamarou.com
49a28efbfc9b2d28e6e167b3c4e60a7d416badfc	59d47cc63b7cfc5bc281a448ba82ccd20f63382e	platform-offer-to-tenants-guard	registry	Registry always keeps a current platform offer to tenants, checked at commit	2026-11-25 01:24:28.322765+00	root	root@vm	2026-11-24 19:00:00+00	Chris Prather	chris.prather@tamarou.com
cd855e623cbb9cf7e60b1c5d2e3d6a15a6e5d864	c7bb07b1f2e58d38a459fe582116c8fa52d2a634	platform-offer-resource-keeps-name	registry	The resource a current platform offer to tenants is for keeps its name	2026-11-25 01:24:28.43018+00	root	root@vm	2026-11-24 20:00:00+00	Chris Prather	chris.prather@tamarou.com
8ad790e56f462911d4768cd91c094d64343c1e8e	68eead1eea4aec23b85012fe077f038f507a10df	payments-offer-version-stamp	registry	A payment is stamped with the offer version it was sold under, fixed once set	2026-11-25 01:24:28.524565+00	root	root@vm	2026-11-24 21:00:00+00	Chris Prather	chris.prather@tamarou.com
abddbe52ed4533f4efc0bb4423aec799763ee573	69eda6e95dda347a1ac7926a6033e55b3ace6e88	drop-pricing-relationships	registry	Drop pricing_relationships, its event log and view, and billing_periods from registry and every tenant schema	2026-11-25 01:24:28.620614+00	root	root@vm	2026-11-24 22:00:00+00	Chris Prather	chris.prather@tamarou.com
9ec6474834d9d6fc8e43ac0f336626e4d837c222	9a06ed3eebb4b2270311c286594ea196e2449352	remove-free-platform-plan	registry	The platform Free plan goes: absence is not zero, so no tenant falls back to 0%	2026-11-25 01:24:28.718294+00	root	root@vm	2026-11-24 23:00:00+00	Chris Prather	chris.prather@tamarou.com
4c1f74488040d08e3d9e72887d056cd5ab60c65f	52936d899c8687e8d8cefe37b1cf7650ffd317e3	entitlement-uses	registry	Marking attendance records one use of the entitlement held for that occurrence, with who and when	2026-11-25 01:24:28.831396+00	root	root@vm	2026-11-25 00:00:00+00	Chris Prather	chris.prather@tamarou.com
7f159e1fb1795c0da3731556dc2c8c4ffe5d4f33	346477fe99aa97d9374e2815a38cfe2839badf4b	holds-placed-at	registry	A hold records when it was placed, so a charge can extend it by its own length	2026-11-25 01:24:28.926642+00	root	root@vm	2026-11-25 01:00:00+00	Chris Prather	chris.prather@tamarou.com
f0fed98016186cb02bfc0481f9e5360d9c621332	8d1f45ccaaa4af8387ef3296c0a7ee17e3564bac	entitlement-refunds-per-entitlement	registry	A Stripe refund is recorded once per entitlement, so one refund can be shared among a payment's entitlements	2026-11-25 01:24:29.017003+00	root	root@vm	2026-11-25 02:00:00+00	Chris Prather	chris.prather@tamarou.com
2860defe903d61948ef856ce7a5bdd386dcdbda0	dafe754b7e8c5578e3dd04b07b009a19038e3846	retire-unpublished-platform-plans	registry	Studio, Empire, Registry Plus and Standard stop being platform plans: Solo is the one offer	2026-11-25 01:24:29.123193+00	root	root@vm	2026-11-25 03:00:00+00	Chris Prather	chris.prather@tamarou.com
\.


--
-- Data for Name: dependencies; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.dependencies (change_id, type, dependency, dependency_id) FROM stdin;
2960f6c6a1df94ef7f1c75a036db14aefe121bc5	require	users	c9235c00bc368836d5323cd4b98cadfa673aa00e
2abd1a15dc06e9db731062527f8541e8c79ffb6f	require	workflows	2960f6c6a1df94ef7f1c75a036db14aefe121bc5
2abd1a15dc06e9db731062527f8541e8c79ffb6f	require	users	c9235c00bc368836d5323cd4b98cadfa673aa00e
2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c	require	tenant-on-boarding	2abd1a15dc06e9db731062527f8541e8c79ffb6f
5920ebcdc5fd6c9478af9fb1e435aedd26b5b5ce	require	schema-based-multitennancy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c
6d1c676dccf7787d99a54edd3ec556193ff0562d	require	schema-based-multitennancy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c
4d1cce9dd15eadfe664b1a909c36f1afd6d943f2	require	schema-based-multitennancy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c
ac009951a991475b6b82050987874c5e1562b227	require	summer-camp-module	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae
ca85da23e2f52eb6ef3b500530d301617d8d64d3	require	summer-camp-module	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae
ca85da23e2f52eb6ef3b500530d301617d8d64d3	require	program-types	4d1cce9dd15eadfe664b1a909c36f1afd6d943f2
9478a08db15d08f6fae783493e14eb2348a478a4	require	summer-camp-module	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae
9478a08db15d08f6fae783493e14eb2348a478a4	require	program-types	4d1cce9dd15eadfe664b1a909c36f1afd6d943f2
125881c219bfb9b9053e66b6b5fb5fdb720a1ee3	require	program-types	4d1cce9dd15eadfe664b1a909c36f1afd6d943f2
b935f44f3eace95edc2fa318ed7de32c27e8ac1a	require	users	c9235c00bc368836d5323cd4b98cadfa673aa00e
7deaa9fb9f8f3d0309d635af087792c28525f78e	require	summer-camp-module	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae
7deaa9fb9f8f3d0309d635af087792c28525f78e	require	add-user-fields-for-family	b935f44f3eace95edc2fa318ed7de32c27e8ac1a
7deaa9fb9f8f3d0309d635af087792c28525f78e	require	program-types	4d1cce9dd15eadfe664b1a909c36f1afd6d943f2
815c14422aeab29c0c21415ea7e8927785a1c910	require	schema-based-multitennancy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c
eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6	require	payments	815c14422aeab29c0c21415ea7e8927785a1c910
eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6	require	summer-camp-module	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae
acd808bf85b5a9d8971f598186ced619196ffd0e	require	attendance-tracking	ca85da23e2f52eb6ef3b500530d301617d8d64d3
5ce709b8eff5b3b920e7a675d78bee9dabd98367	require	notifications-and-preferences	acd808bf85b5a9d8971f598186ced619196ffd0e
fbe73787977942423bb4d7ba5dd152c0c1551e38	require	parent-communication-system	5ce709b8eff5b3b920e7a675d78bee9dabd98367
d7d8aaecb2610865fd3801bb68ef57e474b29181	require	enhanced-pricing-model	ac009951a991475b6b82050987874c5e1562b227
8eb88eeec3cb411430882061df8d5563af64ba1c	require	multi-child-data-model	7deaa9fb9f8f3d0309d635af087792c28525f78e
4883848eccc158220c9e751882d20ae963d71f52	require	fix-multi-child-enrollments	8eb88eeec3cb411430882061df8d5563af64ba1c
f6dbddd094284b0b7296c6e8258922882ae24b5d	require	flexible-enrollment-architecture	4883848eccc158220c9e751882d20ae963d71f52
ffe9a13ee38d1ffa2c706750718b34126adfe6e1	require	remove-student-id-foreign-key	f6dbddd094284b0b7296c6e8258922882ae24b5d
3c3d83d65febc9de2fbce70f02fa01b5483736e8	require	waitlist-management	9478a08db15d08f6fae783493e14eb2348a478a4
300e4d9f1d6bafe1b45f937ea482260f3313760d	require	fix-waitlist-reorder	3c3d83d65febc9de2fbce70f02fa01b5483736e8
0903ffab54af2242711b1cb470a44753acf6c9d7	require	fix-waitlist-reorder-v2	300e4d9f1d6bafe1b45f937ea482260f3313760d
acbd53f8d5ddfc205c3c1ca518ed92170803e32c	require	fix-multi-child-enrollments	8eb88eeec3cb411430882061df8d5563af64ba1c
41ae5ed8ebd0150b8a8c2987bdbfd98967252b18	require	fix-waitlist-reorder-v3	0903ffab54af2242711b1cb470a44753acf6c9d7
788f8edbabafb05aef3b90f4b634beb1aaab7b8b	require	payments	815c14422aeab29c0c21415ea7e8927785a1c910
2fc34cc17316d64ee48ef1c04e4d9c5e096b29ba	require	installment-payment-schedules	788f8edbabafb05aef3b90f4b634beb1aaab7b8b
eb5973974d4f4c06b6e5a93c84b5a66bfcd8f342	require	unified-pricing-infrastructure	f61a99336db06d9d07bd30abcf6e18e98d7609ac
20f187ed4e2e4c35404fcb5f7d48df933cebfcd5	require	consolidate-pricing-relationships	eb5973974d4f4c06b6e5a93c84b5a66bfcd8f342
a2248de7c1f81778ea19e6f9bc5c94e806e21268	require	users	c9235c00bc368836d5323cd4b98cadfa673aa00e
a2248de7c1f81778ea19e6f9bc5c94e806e21268	require	schema-based-multitennancy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c
afdf73989587e92e423e0b5f643361890a90a860	require	notifications-and-preferences	acd808bf85b5a9d8971f598186ced619196ffd0e
afdf73989587e92e423e0b5f643361890a90a860	require	passwordless-auth	a2248de7c1f81778ea19e6f9bc5c94e806e21268
c0834addb5a970c41dc185be91f226cba562e013	require	notifications-and-preferences	acd808bf85b5a9d8971f598186ced619196ffd0e
5656344b5447eb9e8d5b274f18d9fbfffa20f8d4	require	passwordless-auth	a2248de7c1f81778ea19e6f9bc5c94e806e21268
c3c7ae6599f4db30315a79d7021519f29dafa31d	require	waitlist-management	9478a08db15d08f6fae783493e14eb2348a478a4
b1024a8fd0df88c3fd8a543fb5a09512b3fa1cfb	require	events-and-sessions	5920ebcdc5fd6c9478af9fb1e435aedd26b5b5ce
0d0c296e547099f9f75884c8283a0077920abc8c	require	seed-registry-storefront	b1024a8fd0df88c3fd8a543fb5a09512b3fa1cfb
3c41efd35c15d993a9e2b9e7621c7f14de92649e	require	seed-registry-storefront-v2	0d0c296e547099f9f75884c8283a0077920abc8c
730dfd28d76922a358dc3e5eaeb144725df7111e	require	registry-landing-page-template	3c41efd35c15d993a9e2b9e7621c7f14de92649e
4a34ed08664b5ae39f7caacd4f663285efb88267	require	fix-utf8-mojibake	730dfd28d76922a358dc3e5eaeb144725df7111e
44c65bead55e0a35c5372aa2410a7fe5b3bf0e6b	require	summer-camp-module	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae
44c65bead55e0a35c5372aa2410a7fe5b3bf0e6b	require	tenant-domains	c0834addb5a970c41dc185be91f226cba562e013
c2d827c1542f2cf88b9769412919a1ee176147e7	require	auth-notification-types	afdf73989587e92e423e0b5f643361890a90a860
d8dd117aea69688b601f189b8a05f2cc9975b897	require	payments	815c14422aeab29c0c21415ea7e8927785a1c910
bfb052f4957649f0ccf5c59096ee321a100f2886	require	add-payment-to-enrollments	eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6
e9ff0519934e4fcea62f4734c5b9d3b20c09ef4c	require	attendance-tracking	ca85da23e2f52eb6ef3b500530d301617d8d64d3
3c299ff8324976d192be357e48699e64c975784f	require	schema-based-multitennancy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c
3207dcbdd391a3113f62367a901b0319137093bc	require	stripe-subscription-integration	d7d8aaecb2610865fd3801bb68ef57e474b29181
28e0bf2c6d92e23110f116d7ec4bd11d3a37c607	require	payments	815c14422aeab29c0c21415ea7e8927785a1c910
28e0bf2c6d92e23110f116d7ec4bd11d3a37c607	require	installment-payment-schedules	788f8edbabafb05aef3b90f4b634beb1aaab7b8b
28e0bf2c6d92e23110f116d7ec4bd11d3a37c607	require	add-payment-to-enrollments	eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6
28e0bf2c6d92e23110f116d7ec4bd11d3a37c607	require	enrollment-payment-dedup	bfb052f4957649f0ccf5c59096ee321a100f2886
28e0bf2c6d92e23110f116d7ec4bd11d3a37c607	require	tenant-stripe-connect	3207dcbdd391a3113f62367a901b0319137093bc
28d74506683168469a7f47f7ba0500804400ebeb	require	unified-pricing-infrastructure	f61a99336db06d9d07bd30abcf6e18e98d7609ac
ab661862f6c5f4126610587fd3e7da46123c2f04	require	remove-pricing-plan-relationship-fields	5f3d84a4d2158ce0ffcfeabc5772970faca7c3d3
ab661862f6c5f4126610587fd3e7da46123c2f04	require	unified-pricing-infrastructure	f61a99336db06d9d07bd30abcf6e18e98d7609ac
ab661862f6c5f4126610587fd3e7da46123c2f04	require	seed-free-platform-plan	28d74506683168469a7f47f7ba0500804400ebeb
a3a7d4de067885cf24f3b965cee829661b4e7c63	require	create-default-pricing-relationships	ab661862f6c5f4126610587fd3e7da46123c2f04
4f5c0e1ad6352f2a79bd35ab6532bea463f381dc	require	seed-free-platform-plan	28d74506683168469a7f47f7ba0500804400ebeb
f2e5326eff1970535911be0d1222e035d521c000	require	create-default-pricing-relationships	ab661862f6c5f4126610587fd3e7da46123c2f04
0efcbdec112780d02871150d379f0e2b07264241	require	suspend-rateless-tenant-plans	f2e5326eff1970535911be0d1222e035d521c000
d685f3eb74071b32ce295c7722ef57a33c66f5d5	require	pricing-plans-amount-cents	0efcbdec112780d02871150d379f0e2b07264241
723b2c3e0164207d1f004b5584857c3f892cb0cc	require	payments-amount-cents	d685f3eb74071b32ce295c7722ef57a33c66f5d5
7299cb40a004b6904fadeecd2da45cb01f18da03	require	schedule-amounts-cents	723b2c3e0164207d1f004b5584857c3f892cb0cc
1e944e76794f6455bcc241ac32a0cf7ad80786f0	require	schedule-amounts-cents	723b2c3e0164207d1f004b5584857c3f892cb0cc
1e944e76794f6455bcc241ac32a0cf7ad80786f0	require	tenant-scoped-payments	28e0bf2c6d92e23110f116d7ec4bd11d3a37c607
124e93eb6de0fd73c5506f9d21d246c748f42f60	require	suspend-rateless-tenant-plans	f2e5326eff1970535911be0d1222e035d521c000
51493d6426abe6800146664a09dd14c4845ef24c	require	webhook-event-dedup	d8dd117aea69688b601f189b8a05f2cc9975b897
38dbe5f9ef7655079f93ab63a547b6ae7ea6c022	require	refund-amounts-cents	7299cb40a004b6904fadeecd2da45cb01f18da03
cd225459045762634487962815fd105ace1caf30	require	flexible-enrollment-architecture	4883848eccc158220c9e751882d20ae963d71f52
4f4968a7059d18a3163416e0754cd69981058282	require	retire-registry-plus-plan	124e93eb6de0fd73c5506f9d21d246c748f42f60
49f1934e333630282a31ceaf6eeb71898b27d9c5	require	set-launch-revenue-share-rate	4f4968a7059d18a3163416e0754cd69981058282
0f7d16835c8b41ad227ab66d68c36003de68fc21	require	seed-tier-pricing-options	49f1934e333630282a31ceaf6eeb71898b27d9c5
20680f8b72d460b535289c226047d46b15a1a499	require	clear-template-import-stamps	0f7d16835c8b41ad227ab66d68c36003de68fc21
a7040f956947ab1eaa9b1eb52dac77c768d24082	require	tenant-slug-lowercase	20680f8b72d460b535289c226047d46b15a1a499
2a46bba61658475c68afeeaf8a8333220197df38	require	session-waitlist-toggle	a7040f956947ab1eaa9b1eb52dac77c768d24082
e5488490cd4c51eeff34b23533b1a576214ba3dc	require	pricing-plan-versions	2a46bba61658475c68afeeaf8a8333220197df38
3b44ac15d9b45f35b00f7fdcb7bc0455f131f2de	require	user-deactivation	e5488490cd4c51eeff34b23533b1a576214ba3dc
5f054736a12b03dd860447d9c5aa4354124fa7fc	require	tenant-signup-drop-plan-page	3b44ac15d9b45f35b00f7fdcb7bc0455f131f2de
a985ade9d594ea8f7f23d090f87782247ab35b1a	require	tenant-created-from-ip	5f054736a12b03dd860447d9c5aa4354124fa7fc
8b18333bb7b02f9e0b7b8bd9a06119c2bdae7f29	require	instalments-declared-in-configuration	a985ade9d594ea8f7f23d090f87782247ab35b1a
482b7ffee557fb56a318a238cad5bfa863c3ebd3	require	payments-carry-instalments	8b18333bb7b02f9e0b7b8bd9a06119c2bdae7f29
0b109058cb119603bba20014e1c322f8cdbb41bd	require	platform-settings	482b7ffee557fb56a318a238cad5bfa863c3ebd3
9226348ab8a8de0a5d645aab5a60e085d9e5603e	require	magic-link-expiry-one-hour	0b109058cb119603bba20014e1c322f8cdbb41bd
36339a19600bb0603d8b549e379a84d2f4c31770	require	payments-record-platform-fee	9226348ab8a8de0a5d645aab5a60e085d9e5603e
4b26e805ef3f76017e8e2f48bb26f096032c5544	require	waitlist-joined-notification-type	36339a19600bb0603d8b549e379a84d2f4c31770
003b7c0f8200f5fd1ec223e09741654ae9662a4a	require	domain-notification-types	4b26e805ef3f76017e8e2f48bb26f096032c5544
9d8ffe01420a63c9d947f43cfd750757da3dcb62	require	send-cap-setting	003b7c0f8200f5fd1ec223e09741654ae9662a4a
61e86b5860902410a8a28e1a212b299689d11a00	require	workflow-step-label	9d8ffe01420a63c9d947f43cfd750757da3dcb62
f4e3c4f22d425732fcbe9751b2cc4f11b83c9b0a	require	collapse-platform-tenant	61e86b5860902410a8a28e1a212b299689d11a00
b6a2f0778c5f1b8c4f45841129ee9a2d52a1e91a	require	tenant-users-role	f4e3c4f22d425732fcbe9751b2cc4f11b83c9b0a
ca6fec4debbcbf8af172ae04d882036c4b0d132a	require	platform-tenant-unlinks-solo	b6a2f0778c5f1b8c4f45841129ee9a2d52a1e91a
98439380cc75400ca65bc48ee27e7f19a20981df	require	operator-right	ca6fec4debbcbf8af172ae04d882036c4b0d132a
bea3ff7c2f9ee2383a93a41094664bc77bc8e1d7	require	waitlist-offer-notification-types	98439380cc75400ca65bc48ee27e7f19a20981df
e8b8d42aaf2238ce300b9a8934a881ddf24eeeb1	require	tenant-stripe-account-unique	bea3ff7c2f9ee2383a93a41094664bc77bc8e1d7
a672b8f94e5d63882b800757856c05f9cd461fec	require	webhook-events-connect-payload	e8b8d42aaf2238ce300b9a8934a881ddf24eeeb1
47c63377bec3e8cbec9e1027d6b00ebefef03401	require	pricing-plan-rate-check	a672b8f94e5d63882b800757856c05f9cd461fec
25b283927f9405f30b299027f21e58d81f242400	require	payments-platform-fee-refunded	47c63377bec3e8cbec9e1027d6b00ebefef03401
b1afd3dadcbc64642cf1280bb90f683e3aa7e214	require	tenant-plan-has-rate	25b283927f9405f30b299027f21e58d81f242400
4693a092868c7a89538d03a8d72be9ba8a383922	require	priceops-offer-versions	b1afd3dadcbc64642cf1280bb90f683e3aa7e214
9c29b9f3efcea6df803676964f375f39e1b2f9cb	require	priceops-offer-policies	4693a092868c7a89538d03a8d72be9ba8a383922
44af8b065e0e4213dd2658b391307be392b6330a	require	priceops-entitlements	9c29b9f3efcea6df803676964f375f39e1b2f9cb
7aa55c6bc7e28c6e05f161d2c4b9a0297c54b97c	require	priceops-entitlement-one-phase	44af8b065e0e4213dd2658b391307be392b6330a
f9f623bf03447c600f457a7eda26623fe0261165	require	priceops-entitlement-units	7aa55c6bc7e28c6e05f161d2c4b9a0297c54b97c
f4bafd47b218c3ced235d8f4d268ac6f97e74a11	require	priceops-entitlement-lifecycle	f9f623bf03447c600f457a7eda26623fe0261165
c10baef3750b3cb270c857057a98d09391b041a9	require	bootstrap-platform-offers	f4bafd47b218c3ced235d8f4d268ac6f97e74a11
bc3408ec460bb93f449568284cc0d84a5f9e9ab5	require	priceops-occurrence-resources	c10baef3750b3cb270c857057a98d09391b041a9
c12f623ddfbb54d4c55ae4ec2866f0df51b710ca	require	operator-right-entitlement	bc3408ec460bb93f449568284cc0d84a5f9e9ab5
4b0a66a2145016179573b21f17579912018052d5	require	self-offer-guard	c12f623ddfbb54d4c55ae4ec2866f0df51b710ca
53fbbe230350dec54c28791a4e837b9f7cd8f792	require	platform-entitlement-one-in-effect	4b0a66a2145016179573b21f17579912018052d5
c64592d9d2dde57f3eec4c6ebbb3659cb063743b	require	platform-entitlement-replaces-plan-link	53fbbe230350dec54c28791a4e837b9f7cd8f792
f0a4f55ba657aa26ca574bf9ba40872cf441059f	require	offer-publishing-adds-percentage-of-sales	c64592d9d2dde57f3eec4c6ebbb3659cb063743b
62388102bfbedfdd7640f8b026241a36b5f57ab5	require	offer-publishing-adds-use-policy	f0a4f55ba657aa26ca574bf9ba40872cf441059f
73a3d860a6912b73de7c53a9a01b84d88cb98c6f	require	offer-publishing-adds-resource-step	62388102bfbedfdd7640f8b026241a36b5f57ab5
d8a9b842a07bd75be465900ed0d5bb00f05a2fde	require	offer-publishing-adds-refund-policy	73a3d860a6912b73de7c53a9a01b84d88cb98c6f
48de20285d571433867e32335386b105696fba0e	require	offer-publishing-adds-change-policy	d8a9b842a07bd75be465900ed0d5bb00f05a2fde
49a28efbfc9b2d28e6e167b3c4e60a7d416badfc	require	offer-publishing-adds-expiry-policy	48de20285d571433867e32335386b105696fba0e
cd855e623cbb9cf7e60b1c5d2e3d6a15a6e5d864	require	platform-offer-to-tenants-guard	49a28efbfc9b2d28e6e167b3c4e60a7d416badfc
8ad790e56f462911d4768cd91c094d64343c1e8e	require	platform-offer-resource-keeps-name	cd855e623cbb9cf7e60b1c5d2e3d6a15a6e5d864
abddbe52ed4533f4efc0bb4423aec799763ee573	require	payments-offer-version-stamp	8ad790e56f462911d4768cd91c094d64343c1e8e
9ec6474834d9d6fc8e43ac0f336626e4d837c222	require	drop-pricing-relationships	abddbe52ed4533f4efc0bb4423aec799763ee573
4c1f74488040d08e3d9e72887d056cd5ab60c65f	require	remove-free-platform-plan	9ec6474834d9d6fc8e43ac0f336626e4d837c222
7f159e1fb1795c0da3731556dc2c8c4ffe5d4f33	require	entitlement-uses	4c1f74488040d08e3d9e72887d056cd5ab60c65f
f0fed98016186cb02bfc0481f9e5360d9c621332	require	holds-placed-at	7f159e1fb1795c0da3731556dc2c8c4ffe5d4f33
2860defe903d61948ef856ce7a5bdd386dcdbda0	require	entitlement-refunds-per-entitlement	f0fed98016186cb02bfc0481f9e5360d9c621332
\.


--
-- Data for Name: events; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.events (event, change_id, change, project, note, requires, conflicts, tags, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
deploy	c9235c00bc368836d5323cd4b98cadfa673aa00e	users	registry	initial creation of users table and basic schema etc	{}	{}	{}	2026-11-25 01:24:14.969406+00	root	root@vm	2024-05-13 17:21:58+00	Chris Prather	chris@prather.org
deploy	2960f6c6a1df94ef7f1c75a036db14aefe121bc5	workflows	registry	add workflows\n\nWorkflows define a sequence of steps to be executed. We process each step and record the outcome in a workflow run.	{users}	{}	{}	2026-11-25 01:24:15.079194+00	root	root@vm	2024-05-13 17:30:35+00	Chris Prather	chris@prather.org
deploy	2abd1a15dc06e9db731062527f8541e8c79ffb6f	tenant-on-boarding	registry	create an onboarding workflow for tenants	{workflows,users}	{}	{}	2026-11-25 01:24:15.175605+00	root	root@vm	2024-05-20 21:00:32+00	Chris Prather	chris@prather.org
deploy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c	schema-based-multitennancy	registry	add the tools to do the schema-based multi-tenancy	{tenant-on-boarding}	{}	{}	2026-11-25 01:24:15.257381+00	root	root@vm	2024-05-21 01:43:52+00	Chris Prather	chris@prather.org
deploy	5920ebcdc5fd6c9478af9fb1e435aedd26b5b5ce	events-and-sessions	registry	Add events and sessions to the system	{schema-based-multitennancy}	{}	{}	2026-11-25 01:24:15.391743+00	root	root@vm	2024-05-31 03:36:11+00	Chris Prather	chris.prather@tamarou.com
deploy	72bea40753b0250624322f67c9a64fe479f02df7	edit-template-workflow	registry	default workflow for editing templates	{}	{}	{}	2026-11-25 01:24:15.490335+00	root	root@vm	2025-02-11 23:59:19+00	Chris Prather	chris.prather@tamarou.com
deploy	daf665c0e9b4b1255a0cf09bb88e322f6609b59f	outcomes	registry	add outcome definitions	{}	{}	{}	2026-11-25 01:24:15.628867+00	root	root@vm	2025-02-21 06:45:47+00	Chris Prather	chris.prather@tamarou.com
deploy	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae	summer-camp-module	registry	add summer-camp-module	{}	{}	{}	2026-11-25 01:24:15.74121+00	root	root@vm	2025-02-22 04:38:37+00	Chris Prather	chris.prather@tamarou.com
deploy	6d1c676dccf7787d99a54edd3ec556193ff0562d	fix-tenant-workflows	registry	Fix tenant workflows to include first_step	{schema-based-multitennancy}	{}	{}	2026-11-25 01:24:15.863983+00	root	root@vm	2025-03-22 18:57:13+00	Chris Prather	chris.prather@tamarou.com
deploy	4d1cce9dd15eadfe664b1a909c36f1afd6d943f2	program-types	registry	Add program types configuration system	{schema-based-multitennancy}	{}	{}	2026-11-25 01:24:16.016341+00	root	root@vm	2025-01-27 12:00:00+00	Claude	noreply@anthropic.com
deploy	ac009951a991475b6b82050987874c5e1562b227	enhanced-pricing-model	registry	Transform pricing to flexible pricing_plans with multiple tiers per session	{summer-camp-module}	{}	{}	2026-11-25 01:24:16.110419+00	root	root@vm	2025-01-27 12:30:00+00	Claude	noreply@anthropic.com
deploy	ca85da23e2f52eb6ef3b500530d301617d8d64d3	attendance-tracking	registry	Add attendance tracking infrastructure	{summer-camp-module,program-types}	{}	{}	2026-11-25 01:24:16.214206+00	root	root@vm	2025-01-27 13:00:00+00	Claude	noreply@anthropic.com
deploy	9478a08db15d08f6fae783493e14eb2348a478a4	waitlist-management	registry	Add waitlist functionality to enrollment system	{summer-camp-module,program-types}	{}	{}	2026-11-25 01:24:16.327841+00	root	root@vm	2025-01-27 13:30:00+00	Claude	noreply@anthropic.com
deploy	125881c219bfb9b9053e66b6b5fb5fdb720a1ee3	add-program-type-to-projects	registry	Add program type reference to projects	{program-types}	{}	{}	2026-11-25 01:24:16.421827+00	root	root@vm	2025-01-27 14:00:00+00	Claude	noreply@anthropic.com
deploy	b935f44f3eace95edc2fa318ed7de32c27e8ac1a	add-user-fields-for-family	registry	Add birth_date, user_type, grade fields to users	{users}	{}	{}	2026-11-25 01:24:16.504259+00	root	root@vm	2025-01-27 14:25:00+00	Claude	noreply@anthropic.com
deploy	7deaa9fb9f8f3d0309d635af087792c28525f78e	multi-child-data-model	registry	Add family_members table for multi-child support	{summer-camp-module,add-user-fields-for-family,program-types}	{}	{}	2026-11-25 01:24:16.602282+00	root	root@vm	2025-01-27 14:30:00+00	Claude	noreply@anthropic.com
deploy	815c14422aeab29c0c21415ea7e8927785a1c910	payments	registry	Add payments infrastructure for Stripe integration	{schema-based-multitennancy}	{}	{}	2026-11-25 01:24:16.731205+00	root	root@vm	2025-01-27 19:00:00+00	Claude	noreply@anthropic.com
deploy	eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6	add-payment-to-enrollments	registry	Add payment_id reference to enrollments table	{payments,summer-camp-module}	{}	{}	2026-11-25 01:24:16.885709+00	root	root@vm	2025-01-27 19:15:00+00	Claude	noreply@anthropic.com
deploy	acd808bf85b5a9d8971f598186ced619196ffd0e	notifications-and-preferences	registry	Add notifications and user preferences for attendance tracking	{attendance-tracking}	{}	{}	2026-11-25 01:24:17.063207+00	root	root@vm	2025-01-28 10:00:00+00	Claude	noreply@anthropic.com
deploy	5ce709b8eff5b3b920e7a675d78bee9dabd98367	parent-communication-system	registry	Add parent communication system with messages, recipients, and templates	{notifications-and-preferences}	{}	{}	2026-11-25 01:24:17.204319+00	root	root@vm	2025-01-28 11:00:00+00	Claude	noreply@anthropic.com
deploy	fbe73787977942423bb4d7ba5dd152c0c1551e38	performance-optimization	registry	Add database indexes and performance optimizations for production readiness	{parent-communication-system}	{}	{}	2026-11-25 01:24:17.347295+00	root	root@vm	2025-01-28 15:00:00+00	Claude	noreply@anthropic.com
deploy	d7d8aaecb2610865fd3801bb68ef57e474b29181	stripe-subscription-integration	registry	Add Stripe subscription integration for tenant billing	{enhanced-pricing-model}	{}	{}	2026-11-25 01:24:17.460828+00	root	root@vm	2025-01-28 16:00:00+00	Claude	noreply@anthropic.com
deploy	8eb88eeec3cb411430882061df8d5563af64ba1c	fix-multi-child-enrollments	registry	Fix multi-child enrollment constraints for cleaner architecture	{multi-child-data-model}	{}	{}	2026-11-25 01:24:17.571569+00	root	root@vm	2025-07-15 00:34:24+00	Chris Prather	chris.prather@tamarou.com
deploy	4883848eccc158220c9e751882d20ae963d71f52	flexible-enrollment-architecture	registry	Create flexible enrollment architecture supporting family, individual, group, and corporate students	{fix-multi-child-enrollments}	{}	{}	2026-11-25 01:24:17.732424+00	root	root@vm	2025-07-15 01:09:59+00	Chris Prather	chris.prather@tamarou.com
deploy	f6dbddd094284b0b7296c6e8258922882ae24b5d	remove-student-id-foreign-key	registry	Remove student_id foreign key constraint to support polymorphic student references	{flexible-enrollment-architecture}	{}	{}	2026-11-25 01:24:17.827115+00	root	root@vm	2025-07-15 01:28:59+00	Chris Prather	chris.prather@tamarou.com
deploy	ffe9a13ee38d1ffa2c706750718b34126adfe6e1	fix-waitlist-family-member-refs	registry	Fix waitlist student_id to reference family_members instead of users	{remove-student-id-foreign-key}	{}	{}	2026-11-25 01:24:17.904403+00	root	root@vm	2025-07-16 14:30:00+00	Claude	noreply@anthropic.com
deploy	3c3d83d65febc9de2fbce70f02fa01b5483736e8	fix-waitlist-reorder	registry	Fix waitlist position reordering to avoid unique constraint violations	{waitlist-management}	{}	{}	2026-11-25 01:24:17.987876+00	root	root@vm	2025-07-16 12:30:00+00	Claude	noreply@anthropic.com
deploy	300e4d9f1d6bafe1b45f937ea482260f3313760d	fix-waitlist-reorder-v2	registry	Improved waitlist position reordering to fully avoid constraint violations	{fix-waitlist-reorder}	{}	{}	2026-11-25 01:24:18.102059+00	root	root@vm	2025-07-16 22:50:00+00	Claude	noreply@anthropic.com
deploy	0903ffab54af2242711b1cb470a44753acf6c9d7	fix-waitlist-reorder-v3	registry	Remove problematic database trigger and handle position reordering in application code	{fix-waitlist-reorder-v2}	{}	{}	2026-11-25 01:24:18.217966+00	root	root@vm	2025-07-17 00:00:00+00	Claude	noreply@anthropic.com
deploy	acbd53f8d5ddfc205c3c1ca518ed92170803e32c	drop-transfer-business-rules	registry	Add drop and transfer business rules with admin approval workflow	{fix-multi-child-enrollments}	{}	{}	2026-11-25 01:24:18.339016+00	root	root@vm	2025-09-18 00:00:00+00	Claude	noreply@anthropic.com
deploy	41ae5ed8ebd0150b8a8c2987bdbfd98967252b18	remove-waitlist-position-constraint	registry	Remove unique constraint on waitlist position to allow status-based visibility	{fix-waitlist-reorder-v3}	{}	{}	2026-11-25 01:24:18.431083+00	root	root@vm	2025-09-21 00:00:00+00	Claude	noreply@anthropic.com
deploy	788f8edbabafb05aef3b90f4b634beb1aaab7b8b	installment-payment-schedules	registry	Add payment schedules and scheduled payments for installment processing	{payments}	{}	{}	2026-11-25 01:24:18.537336+00	root	root@vm	2025-09-23 03:35:05+00	Chris Prather	chris.prather@tamarou.com
deploy	2fc34cc17316d64ee48ef1c04e4d9c5e096b29ba	simplify-installment-schema-for-stripe	registry	Simplify database schema to use Stripe native scheduling and retry features	{installment-payment-schedules}	{}	{}	2026-11-25 01:24:18.632142+00	root	root@vm	2025-09-24 18:00:00+00	Claude	noreply@anthropic.com
deploy	f61a99336db06d9d07bd30abcf6e18e98d7609ac	unified-pricing-infrastructure	registry	Add unified tenant-to-tenant pricing infrastructure	{}	{}	{}	2026-11-25 01:24:18.776375+00	root	root@vm	2025-09-29 00:44:03+00	Chris Prather	chris.prather@tamarou.com
deploy	eb5973974d4f4c06b6e5a93c84b5a66bfcd8f342	consolidate-pricing-relationships	registry	Consolidate pricing relationships into unified model	{unified-pricing-infrastructure}	{}	{}	2026-11-25 01:24:18.930316+00	root	root@vm	2025-09-29 16:07:15+00	Chris Prather	chris.prather@tamarou.com
deploy	20f187ed4e2e4c35404fcb5f7d48df933cebfcd5	pricing-relationship-events	registry	Add event sourcing for pricing relationship audit trail	{consolidate-pricing-relationships}	{}	{}	2026-11-25 01:24:19.067497+00	root	root@vm	2025-09-29 19:55:59+00	Chris Prather	chris.prather@tamarou.com
deploy	5f3d84a4d2158ce0ffcfeabc5772970faca7c3d3	remove-pricing-plan-relationship-fields	registry	Remove obsolete target_tenant_id and offering_tenant_id from pricing_plans	{}	{}	{}	2026-11-25 01:24:19.156435+00	root	root@vm	2025-09-29 22:27:51+00	Chris Prather	chris.prather@tamarou.com
deploy	a2248de7c1f81778ea19e6f9bc5c94e806e21268	passwordless-auth	registry	Passwordless auth: passkeys, magic links, API keys	{users,schema-based-multitennancy}	{}	{}	2026-11-25 01:24:19.267598+00	root	root@vm	2026-03-25 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	afdf73989587e92e423e0b5f643361890a90a860	auth-notification-types	registry	Add auth notification types to notification_type enum	{notifications-and-preferences,passwordless-auth}	{}	{}	2026-11-25 01:24:19.366264+00	root	root@vm	2026-03-30 06:56:54+00	Chris Prather	chris.prather@tamarou.com
deploy	c0834addb5a970c41dc185be91f226cba562e013	tenant-domains	registry	Custom domain management for tenants	{notifications-and-preferences}	{}	{}	2026-11-25 01:24:19.484332+00	root	root@vm	2026-03-30 19:04:42+00	Chris Prather	chris.prather@tamarou.com
deploy	5656344b5447eb9e8d5b274f18d9fbfffa20f8d4	magic-link-verification	registry	Add verified_at column for two-step magic link flow	{passwordless-auth}	{}	{}	2026-11-25 01:24:19.572444+00	root	root@vm	2026-03-31 12:11:05+00	Chris Prather	chris.prather@tamarou.com
deploy	c3c7ae6599f4db30315a79d7021519f29dafa31d	waitlist-accepted-status	registry	Add accepted status to waitlist check constraint	{waitlist-management}	{}	{}	2026-11-25 01:24:19.667389+00	root	root@vm	2026-04-05 01:37:21+00	Chris Prather	chris.prather@tamarou.com
deploy	b1024a8fd0df88c3fd8a543fb5a09512b3fa1cfb	seed-registry-storefront	registry	Seed registry tenant storefront (empty stub, deployed to production)	{events-and-sessions}	{}	{}	2026-11-25 01:24:19.75684+00	root	root@vm	2026-04-07 13:42:30+00	Chris Prather	chris.prather@tamarou.com
deploy	0d0c296e547099f9f75884c8283a0077920abc8c	seed-registry-storefront-v2	registry	Seed registry tenant storefront with actual data	{seed-registry-storefront}	{}	{}	2026-11-25 01:24:19.85409+00	root	root@vm	2026-04-07 14:44:00+00	Chris Prather	chris.prather@tamarou.com
deploy	3c41efd35c15d993a9e2b9e7621c7f14de92649e	registry-landing-page-template	registry	Customize registry tenant landing page for Jordan's user journey	{seed-registry-storefront-v2}	{}	{}	2026-11-25 01:24:19.954716+00	root	root@vm	2026-04-11 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	730dfd28d76922a358dc3e5eaeb144725df7111e	fix-utf8-mojibake	registry	Delete DB templates with mojibake so app reimports fixed versions	{registry-landing-page-template}	{}	{}	2026-11-25 01:24:20.062901+00	root	root@vm	2026-04-11 12:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	4a34ed08664b5ae39f7caacd4f663285efb88267	update-registry-landing-copy	registry	Update registry landing page copy and 3x2 card grid	{fix-utf8-mojibake}	{}	{}	2026-11-25 01:24:20.187963+00	root	root@vm	2026-04-11 14:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	44c65bead55e0a35c5372aa2410a7fe5b3bf0e6b	program-publish-status	registry	Add status to projects and contact_person_id to locations for admin program setup	{summer-camp-module,tenant-domains}	{}	{}	2026-11-25 01:24:20.316919+00	root	root@vm	2026-04-19 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	c2d827c1542f2cf88b9769412919a1ee176147e7	enrollment-confirmation-notification-type	registry	Add enrollment_confirmation notification type	{auth-notification-types}	{}	{}	2026-11-25 01:24:20.411654+00	root	root@vm	2026-04-23 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	d8dd117aea69688b601f189b8a05f2cc9975b897	webhook-event-dedup	registry	Track processed Stripe webhook event IDs for deduplication	{payments}	{}	{}	2026-11-25 01:24:20.542903+00	root	root@vm	2026-06-01 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	bfb052f4957649f0ccf5c59096ee321a100f2886	enrollment-payment-dedup	registry	Unique index to make paid-enrollment finalization idempotent	{add-payment-to-enrollments}	{}	{}	2026-11-25 01:24:20.648065+00	root	root@vm	2026-06-01 01:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	e9ff0519934e4fcea62f4734c5b9d3b20c09ef4c	fix-attendance-student-id-fkey	registry	Remove student_id FK from attendance_records to allow polymorphic family_member references	{attendance-tracking}	{}	{}	2026-11-25 01:24:20.809724+00	root	root@vm	2026-06-08 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	3c299ff8324976d192be357e48699e64c975784f	fix-clone-schema-identifier-quoting	registry	Quote dest_schema consistently with quote_ident in clone_schema to support reserved-word schema names	{schema-based-multitennancy}	{}	{}	2026-11-25 01:24:20.897868+00	root	root@vm	2026-06-10 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	3207dcbdd391a3113f62367a901b0319137093bc	tenant-stripe-connect	registry	Add per-tenant Stripe Connect account and readiness flags for destination charges	{stripe-subscription-integration}	{}	{}	2026-11-25 01:24:20.985488+00	root	root@vm	2026-06-10 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	28e0bf2c6d92e23110f116d7ec4bd11d3a37c607	tenant-scoped-payments	registry	Move payment tables into tenant schemas and repoint enrollments.payment_id FK for tenant-local payment isolation	{payments,installment-payment-schedules,add-payment-to-enrollments,enrollment-payment-dedup,tenant-stripe-connect}	{}	{}	2026-11-25 01:24:21.098642+00	root	root@vm	2026-06-10 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	28d74506683168469a7f47f7ba0500804400ebeb	seed-free-platform-plan	registry	Seed platform-scope Free (0%) fallback plan	{unified-pricing-infrastructure}	{}	{}	2026-11-25 01:24:21.197105+00	root	root@vm	2026-06-13 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	ab661862f6c5f4126610587fd3e7da46123c2f04	create-default-pricing-relationships	registry	Create active platform relationships so tenant plans are selectable	{remove-pricing-plan-relationship-fields,unified-pricing-infrastructure,seed-free-platform-plan}	{}	{}	2026-11-25 01:24:21.316814+00	root	root@vm	2026-06-13 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	a3a7d4de067885cf24f3b965cee829661b4e7c63	tenant-platform-pricing-plan	registry	Add tenants.platform_pricing_plan_id FK and backfill existing tenants	{create-default-pricing-relationships}	{}	{}	2026-11-25 01:24:21.449775+00	root	root@vm	2026-06-16 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	4f5c0e1ad6352f2a79bd35ab6532bea463f381dc	refund-application-fee-config	registry	Declare refund_application_fee on seeded platform + tenant plans	{seed-free-platform-plan}	{}	{}	2026-11-25 01:24:21.551329+00	root	root@vm	2026-07-03 23:09:47+00	Chris Prather	chris.prather@tamarou.com
deploy	f2e5326eff1970535911be0d1222e035d521c000	suspend-rateless-tenant-plans	registry	Stop offering tenant plans with no resolvable revenue-share rate	{create-default-pricing-relationships}	{}	{}	2026-11-25 01:24:21.693856+00	root	root@vm	2026-08-03 23:18:43+00	Chris Prather	chris.prather@tamarou.com
deploy	0efcbdec112780d02871150d379f0e2b07264241	pricing-plans-amount-cents	registry	Store pricing_plans money as integer cents; the rate lives only in pricing_configuration	{suspend-rateless-tenant-plans}	{}	{}	2026-11-25 01:24:21.808815+00	root	root@vm	2026-08-06 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	d685f3eb74071b32ce295c7722ef57a33c66f5d5	payments-amount-cents	registry	Store payments and payment_items money as integer cents	{pricing-plans-amount-cents}	{}	{}	2026-11-25 01:24:21.92908+00	root	root@vm	2026-08-06 12:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	723b2c3e0164207d1f004b5584857c3f892cb0cc	schedule-amounts-cents	registry	Store installment schedule money as integer cents	{payments-amount-cents}	{}	{}	2026-11-25 01:24:22.071481+00	root	root@vm	2026-08-06 13:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	7299cb40a004b6904fadeecd2da45cb01f18da03	refund-amounts-cents	registry	Store refund money as integer cents	{schedule-amounts-cents}	{}	{}	2026-11-25 01:24:22.215393+00	root	root@vm	2026-08-06 14:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	1e944e76794f6455bcc241ac32a0cf7ad80786f0	drop-installment-schedules	registry	Drop the installment schedule tables from registry and every tenant schema	{schedule-amounts-cents,tenant-scoped-payments}	{}	{}	2026-11-25 01:24:22.310951+00	root	root@vm	2026-08-13 13:50:16+00	Chris Prather	chris.prather@tamarou.com
deploy	124e93eb6de0fd73c5506f9d21d246c748f42f60	retire-registry-plus-plan	registry	Stop offering the seeded Registry Plus hybrid plan	{suspend-rateless-tenant-plans}	{}	{}	2026-11-25 01:24:22.416205+00	root	root@vm	2026-08-13 14:37:13+00	Chris Prather	chris.prather@tamarou.com
deploy	51493d6426abe6800146664a09dd14c4845ef24c	webhook-events-processed-at	registry	Add processed_at to registry.webhook_events for received-to-processed latency	{webhook-event-dedup}	{}	{}	2026-11-25 01:24:22.519407+00	root	root@vm	2026-08-15 14:37:28+00	Chris Prather	chris.prather@tamarou.com
deploy	38dbe5f9ef7655079f93ab63a547b6ae7ea6c022	payments-typed-obligation	registry	Typed columns for the capacity-refund obligation, and a CHECK on payments.status	{refund-amounts-cents}	{}	{}	2026-11-25 01:24:22.664957+00	root	root@vm	2026-08-22 23:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	cd225459045762634487962815fd105ace1caf30	enrollment-reenrol-after-drop	registry	A cancelled enrollment stops occupying its seat, so a dropped child can re-join	{flexible-enrollment-architecture}	{}	{}	2026-11-25 01:24:22.782626+00	root	root@vm	2026-08-26 22:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	4f4968a7059d18a3163416e0754cd69981058282	set-launch-revenue-share-rate	registry	Move the offered revenue-share plan to the launch rate and mark it as the launch plan	{retire-registry-plus-plan}	{}	{}	2026-11-25 01:24:22.890283+00	root	root@vm	2026-09-04 14:50:00+00	Chris Prather	chris.prather@tamarou.com
deploy	49f1934e333630282a31ceaf6eeb71898b27d9c5	seed-tier-pricing-options	registry	Put the Solo/Studio/Empire tier model into the plans the signup page renders	{set-launch-revenue-share-rate}	{}	{}	2026-11-25 01:24:22.987568+00	root	root@vm	2026-09-04 16:05:00+00	Chris Prather	chris.prather@tamarou.com
deploy	0f7d16835c8b41ad227ab66d68c36003de68fc21	clear-template-import-stamps	registry	Drop stamps computed from bytes so the fixed character-based import re-stamps every row	{seed-tier-pricing-options}	{}	{}	2026-11-25 01:24:23.104455+00	root	root@vm	2026-09-13 21:15:00+00	Chris Prather	chris.prather@tamarou.com
deploy	20680f8b72d460b535289c226047d46b15a1a499	tenant-slug-lowercase	registry	Tenant slugs must be lowercase: clone_schema case-folds an unquoted dest_schema	{clear-template-import-stamps}	{}	{}	2026-11-25 01:24:23.210886+00	root	root@vm	2026-09-14 04:05:00+00	Chris Prather	chris.prather@tamarou.com
deploy	a7040f956947ab1eaa9b1eb52dac77c768d24082	session-waitlist-toggle	registry	A session can turn its waitlist off, so a full one is simply full	{tenant-slug-lowercase}	{}	{}	2026-11-25 01:24:23.323895+00	root	root@vm	2026-09-24 12:10:00+00	Chris Prather	chris.prather@tamarou.com
deploy	2a46bba61658475c68afeeaf8a8333220197df38	pricing-plan-versions	registry	Pricing plans become append-only versions, and a charge records the version it used	{session-waitlist-toggle}	{}	{}	2026-11-25 01:24:23.447109+00	root	root@vm	2026-09-26 19:20:00+00	Chris Prather	chris.prather@tamarou.com
deploy	e5488490cd4c51eeff34b23533b1a576214ba3dc	user-deactivation	registry	A departed staff member can be deactivated, which revokes every way in	{pricing-plan-versions}	{}	{}	2026-11-25 01:24:23.582934+00	root	root@vm	2026-09-27 15:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	3b44ac15d9b45f35b00f7fdcb7bc0455f131f2de	tenant-signup-drop-plan-page	registry	Signup stops asking which plan: everyone starts on the one tier that is on sale	{user-deactivation}	{}	{}	2026-11-25 01:24:23.675524+00	root	root@vm	2026-09-28 17:45:00+00	Chris Prather	chris.prather@tamarou.com
deploy	5f054736a12b03dd860447d9c5aa4354124fa7fc	tenant-created-from-ip	registry	Record which address provisioned a tenant, so the clone cost can be bounded	{tenant-signup-drop-plan-page}	{}	{}	2026-11-25 01:24:23.804394+00	root	root@vm	2026-09-28 23:20:00+00	Chris Prather	chris.prather@tamarou.com
deploy	a985ade9d594ea8f7f23d090f87782247ab35b1a	instalments-declared-in-configuration	registry	An instalment offer becomes a declared shape rather than a boolean and a count	{tenant-created-from-ip}	{}	{}	2026-11-25 01:24:23.932403+00	root	root@vm	2026-09-29 17:55:00+00	Chris Prather	chris.prather@tamarou.com
deploy	8b18333bb7b02f9e0b7b8bd9a06119c2bdae7f29	payments-carry-instalments	registry	A payment can be one instalment of several, recorded at enrolment rather than derived from Stripe	{instalments-declared-in-configuration}	{}	{}	2026-11-25 01:24:24.057987+00	root	root@vm	2026-09-29 19:40:00+00	Chris Prather	chris.prather@tamarou.com
deploy	482b7ffee557fb56a318a238cad5bfa863c3ebd3	platform-settings	registry	Platform configuration Alex can see and change without a deploy	{payments-carry-instalments}	{}	{}	2026-11-25 01:24:24.163154+00	root	root@vm	2026-09-30 15:45:00+00	Chris Prather	chris.prather@tamarou.com
deploy	0b109058cb119603bba20014e1c322f8cdbb41bd	magic-link-expiry-one-hour	registry	A magic link lasts an hour rather than a day	{platform-settings}	{}	{}	2026-11-25 01:24:24.283796+00	root	root@vm	2026-10-03 00:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	9226348ab8a8de0a5d645aab5a60e085d9e5603e	payments-record-platform-fee	registry	Record what the platform took on a charge, and the plan version it took it under	{magic-link-expiry-one-hour}	{}	{}	2026-11-25 01:24:24.382999+00	root	root@vm	2026-10-05 18:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	36339a19600bb0603d8b549e379a84d2f4c31770	waitlist-joined-notification-type	registry	A parent who joins a waitlist gets it in writing	{payments-record-platform-fee}	{}	{}	2026-11-25 01:24:24.495062+00	root	root@vm	2026-10-08 17:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	4b26e805ef3f76017e8e2f48bb26f096032c5544	domain-notification-types	registry	A tenant hears the outcome of domain verification	{waitlist-joined-notification-type}	{}	{}	2026-11-25 01:24:24.604565+00	root	root@vm	2026-10-10 14:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	003b7c0f8200f5fd1ec223e09741654ae9662a4a	send-cap-setting	registry	The unverified-tenant send cap is a row Alex can change	{domain-notification-types}	{}	{}	2026-11-25 01:24:24.706584+00	root	root@vm	2026-10-10 19:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	9d8ffe01420a63c9d947f43cfd750757da3dcb62	workflow-step-label	registry	A workflow step has a name a person can read, beside the note for developers	{send-cap-setting}	{}	{}	2026-11-25 01:24:24.810422+00	root	root@vm	2026-10-13 16:10:00+00	Chris Prather	chris.prather@tamarou.com
deploy	61e86b5860902410a8a28e1a212b299689d11a00	collapse-platform-tenant	registry	The platform is one tenant row: the all-zeros row, slug registry	{workflow-step-label}	{}	{}	2026-11-25 01:24:24.935567+00	root	root@vm	2026-11-23 12:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	f4e3c4f22d425732fcbe9751b2cc4f11b83c9b0a	tenant-users-role	registry	A membership carries its own role, so authority is read per tenant	{collapse-platform-tenant}	{}	{}	2026-11-25 01:24:25.033329+00	root	root@vm	2026-11-23 18:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	b6a2f0778c5f1b8c4f45841129ee9a2d52a1e91a	platform-tenant-unlinks-solo	registry	The platform takes no share of its own sales	{tenant-users-role}	{}	{}	2026-11-25 01:24:25.139603+00	root	root@vm	2026-11-23 20:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	ca6fec4debbcbf8af172ae04d882036c4b0d132a	operator-right	registry	The platform tenant holds the operator right as seeded data	{platform-tenant-unlinks-solo}	{}	{}	2026-11-25 01:24:25.246762+00	root	root@vm	2026-11-23 22:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	98439380cc75400ca65bc48ee27e7f19a20981df	waitlist-offer-notification-types	registry	A parent who opted in hears about a waitlist offer and its expiry	{operator-right}	{}	{}	2026-11-25 01:24:25.353942+00	root	root@vm	2026-11-23 23:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	bea3ff7c2f9ee2383a93a41094664bc77bc8e1d7	tenant-stripe-account-unique	registry	A Stripe account id belongs to one tenant at most	{waitlist-offer-notification-types}	{}	{}	2026-11-25 01:24:25.474345+00	root	root@vm	2026-11-24 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	e8b8d42aaf2238ce300b9a8934a881ddf24eeeb1	webhook-events-connect-payload	registry	Store refund, dispute and customer events from the Connect endpoint for later	{tenant-stripe-account-unique}	{}	{}	2026-11-25 01:24:25.599296+00	root	root@vm	2026-11-24 01:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	a672b8f94e5d63882b800757856c05f9cd461fec	pricing-plan-rate-check	registry	A plan rate written in SQL is held to the rule PricingPlan->create enforces	{webhook-events-connect-payload}	{}	{}	2026-11-25 01:24:25.744331+00	root	root@vm	2026-11-24 02:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	47c63377bec3e8cbec9e1027d6b00ebefef03401	payments-platform-fee-refunded	registry	Record how much of the platform fee Stripe reports refunded	{pricing-plan-rate-check}	{}	{}	2026-11-25 01:24:25.843289+00	root	root@vm	2026-11-24 03:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	25b283927f9405f30b299027f21e58d81f242400	tenant-plan-has-rate	registry	A tenant links only to a platform plan that carries a rate	{payments-platform-fee-refunded}	{}	{}	2026-11-25 01:24:25.960981+00	root	root@vm	2026-11-24 03:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	b1afd3dadcbc64642cf1280bb90f683e3aa7e214	priceops-offer-versions	registry	Resources and offers with append-only versions, immutable once published	{tenant-plan-has-rate}	{}	{}	2026-11-25 01:24:26.160424+00	root	root@vm	2026-11-24 04:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	4693a092868c7a89538d03a8d72be9ba8a383922	priceops-offer-policies	registry	Offer versions carry price, units, payment plans, policies and conditions as data	{priceops-offer-versions}	{}	{}	2026-11-25 01:24:26.322869+00	root	root@vm	2026-11-24 05:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	9c29b9f3efcea6df803676964f375f39e1b2f9cb	priceops-entitlements	registry	Entitlements record holder, payer, stamped offer version and plan, and in-effect period	{priceops-offer-policies}	{}	{}	2026-11-25 01:24:26.440727+00	root	root@vm	2026-11-24 06:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	44af8b065e0e4213dd2658b391307be392b6330a	priceops-entitlement-one-phase	registry	One schedule phase of an offer in effect at a time per holder, by exclusion constraint	{priceops-entitlements}	{}	{}	2026-11-25 01:24:26.623314+00	root	root@vm	2026-11-24 07:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	7aa55c6bc7e28c6e05f161d2c4b9a0297c54b97c	priceops-entitlement-units	registry	A discrete entitlement holds named units of a finite resource, never past its capacity	{priceops-entitlement-one-phase}	{}	{}	2026-11-25 01:24:26.757568+00	root	root@vm	2026-11-24 07:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	f9f623bf03447c600f457a7eda26623fe0261165	priceops-entitlement-lifecycle	registry	An entitlement is active or ended once, with when and why, and links to the payment that created it	{priceops-entitlement-units}	{}	{}	2026-11-25 01:24:26.863998+00	root	root@vm	2026-11-24 08:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	f4bafd47b218c3ced235d8f4d268ac6f97e74a11	bootstrap-platform-offers	registry	The bootstrap seeds Solo v1 and the platform's offers to itself, with registry's entitlements	{priceops-entitlement-lifecycle}	{}	{}	2026-11-25 01:24:26.964729+00	root	root@vm	2026-11-24 08:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	c10baef3750b3cb270c857057a98d09391b041a9	priceops-occurrence-resources	registry	An occurrence is its own finite resource, and a class offer covers its class's occurrences	{bootstrap-platform-offers}	{}	{}	2026-11-25 01:24:27.076806+00	root	root@vm	2026-11-24 09:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	bc3408ec460bb93f449568284cc0d84a5f9e9ab5	operator-right-entitlement	registry	The platform holds the operator right as an entitlement, and the interim table goes	{priceops-occurrence-resources}	{}	{}	2026-11-25 01:24:27.226958+00	root	root@vm	2026-11-24 09:30:00+00	Chris Prather	chris.prather@tamarou.com
deploy	c12f623ddfbb54d4c55ae4ec2866f0df51b710ca	self-offer-guard	registry	Only the platform tenant may hold the platform's offers to itself (holder_is_offerer)	{operator-right-entitlement}	{}	{}	2026-11-25 01:24:27.331315+00	root	root@vm	2026-11-24 10:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	4b0a66a2145016179573b21f17579912018052d5	platform-entitlement-one-in-effect	registry	A tenant holds one active platform entitlement to payment processing at a time	{self-offer-guard}	{}	{}	2026-11-25 01:24:27.42795+00	root	root@vm	2026-11-24 11:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	53fbbe230350dec54c28791a4e837b9f7cd8f792	platform-entitlement-replaces-plan-link	registry	A tenant's platform fee comes from its platform entitlement, and the plan link is dropped	{platform-entitlement-one-in-effect}	{}	{}	2026-11-25 01:24:27.547871+00	root	root@vm	2026-11-24 12:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	c64592d9d2dde57f3eec4c6ebbb3659cb063743b	offer-publishing-adds-percentage-of-sales	registry	offer-publishing gains a percentage-of-sales payment step; the stored workflow is cleared so import rebuilds it	{platform-entitlement-replaces-plan-link}	{}	{}	2026-11-25 01:24:27.656807+00	root	root@vm	2026-11-24 13:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	f0a4f55ba657aa26ca574bf9ba40872cf441059f	offer-publishing-adds-use-policy	registry	offer-publishing asks for a use policy, so the stored workflow is rebuilt from YAML	{offer-publishing-adds-percentage-of-sales}	{}	{}	2026-11-25 01:24:27.763969+00	root	root@vm	2026-11-24 14:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	62388102bfbedfdd7640f8b026241a36b5f57ab5	offer-publishing-adds-resource-step	registry	offer-publishing starts at a resource step, so the stored workflow is cleared for re-import	{offer-publishing-adds-use-policy}	{}	{}	2026-11-25 01:24:27.8727+00	root	root@vm	2026-11-24 15:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	73a3d860a6912b73de7c53a9a01b84d88cb98c6f	offer-publishing-adds-refund-policy	registry	offer-publishing asks for a refund policy at its own step, so the stored workflow is rebuilt from YAML	{offer-publishing-adds-resource-step}	{}	{}	2026-11-25 01:24:27.991039+00	root	root@vm	2026-11-24 16:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	d8a9b842a07bd75be465900ed0d5bb00f05a2fde	offer-publishing-adds-change-policy	registry	offer-publishing asks for a change policy, so the stored workflow is rebuilt from YAML	{offer-publishing-adds-refund-policy}	{}	{}	2026-11-25 01:24:28.106766+00	root	root@vm	2026-11-24 17:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	48de20285d571433867e32335386b105696fba0e	offer-publishing-adds-expiry-policy	registry	offer-publishing asks for an expiry policy, so the stored workflow is rebuilt from YAML	{offer-publishing-adds-change-policy}	{}	{}	2026-11-25 01:24:28.213594+00	root	root@vm	2026-11-24 18:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	49a28efbfc9b2d28e6e167b3c4e60a7d416badfc	platform-offer-to-tenants-guard	registry	Registry always keeps a current platform offer to tenants, checked at commit	{offer-publishing-adds-expiry-policy}	{}	{}	2026-11-25 01:24:28.323773+00	root	root@vm	2026-11-24 19:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	cd855e623cbb9cf7e60b1c5d2e3d6a15a6e5d864	platform-offer-resource-keeps-name	registry	The resource a current platform offer to tenants is for keeps its name	{platform-offer-to-tenants-guard}	{}	{}	2026-11-25 01:24:28.431199+00	root	root@vm	2026-11-24 20:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	8ad790e56f462911d4768cd91c094d64343c1e8e	payments-offer-version-stamp	registry	A payment is stamped with the offer version it was sold under, fixed once set	{platform-offer-resource-keeps-name}	{}	{}	2026-11-25 01:24:28.526444+00	root	root@vm	2026-11-24 21:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	abddbe52ed4533f4efc0bb4423aec799763ee573	drop-pricing-relationships	registry	Drop pricing_relationships, its event log and view, and billing_periods from registry and every tenant schema	{payments-offer-version-stamp}	{}	{}	2026-11-25 01:24:28.621434+00	root	root@vm	2026-11-24 22:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	9ec6474834d9d6fc8e43ac0f336626e4d837c222	remove-free-platform-plan	registry	The platform Free plan goes: absence is not zero, so no tenant falls back to 0%	{drop-pricing-relationships}	{}	{}	2026-11-25 01:24:28.719459+00	root	root@vm	2026-11-24 23:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	4c1f74488040d08e3d9e72887d056cd5ab60c65f	entitlement-uses	registry	Marking attendance records one use of the entitlement held for that occurrence, with who and when	{remove-free-platform-plan}	{}	{}	2026-11-25 01:24:28.834649+00	root	root@vm	2026-11-25 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	7f159e1fb1795c0da3731556dc2c8c4ffe5d4f33	holds-placed-at	registry	A hold records when it was placed, so a charge can extend it by its own length	{entitlement-uses}	{}	{}	2026-11-25 01:24:28.927609+00	root	root@vm	2026-11-25 01:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	f0fed98016186cb02bfc0481f9e5360d9c621332	entitlement-refunds-per-entitlement	registry	A Stripe refund is recorded once per entitlement, so one refund can be shared among a payment's entitlements	{holds-placed-at}	{}	{}	2026-11-25 01:24:29.017982+00	root	root@vm	2026-11-25 02:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	2860defe903d61948ef856ce7a5bdd386dcdbda0	retire-unpublished-platform-plans	registry	Studio, Empire, Registry Plus and Standard stop being platform plans: Solo is the one offer	{entitlement-refunds-per-entitlement}	{}	{}	2026-11-25 01:24:29.124385+00	root	root@vm	2026-11-25 03:00:00+00	Chris Prather	chris.prather@tamarou.com
\.


--
-- Data for Name: projects; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.projects (project, uri, created_at, creator_name, creator_email) FROM stdin;
registry	\N	2026-11-25 01:24:14.83763+00	root	root@vm
\.


--
-- Data for Name: releases; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.releases (version, installed_at, installer_name, installer_email) FROM stdin;
1.1	2026-11-25 01:24:14.83674+00	root	root@vm
\.


--
-- Data for Name: tags; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.tags (tag_id, tag, project, change_id, note, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
\.


--
-- Name: api_keys api_keys_key_hash_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.api_keys
    ADD CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: attendance_records attendance_records_event_id_student_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.attendance_records
    ADD CONSTRAINT attendance_records_event_id_student_id_key UNIQUE (event_id, student_id);


--
-- Name: attendance_records attendance_records_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.attendance_records
    ADD CONSTRAINT attendance_records_pkey PRIMARY KEY (id);


--
-- Name: drop_requests drop_requests_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.drop_requests
    ADD CONSTRAINT drop_requests_pkey PRIMARY KEY (id);


--
-- Name: enrollments enrollments_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_pkey PRIMARY KEY (id);


--
-- Name: entitlement_refunds entitlement_refunds_entitlement_id_stripe_refund_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_refunds
    ADD CONSTRAINT entitlement_refunds_entitlement_id_stripe_refund_id_key UNIQUE (entitlement_id, stripe_refund_id);


--
-- Name: entitlement_refunds entitlement_refunds_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_refunds
    ADD CONSTRAINT entitlement_refunds_pkey PRIMARY KEY (id);


--
-- Name: entitlement_units entitlement_units_entitlement_id_resource_id_excl; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_units
    ADD CONSTRAINT entitlement_units_entitlement_id_resource_id_excl EXCLUDE USING gist (entitlement_id WITH =, resource_id WITH <>);


--
-- Name: entitlement_units entitlement_units_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_units
    ADD CONSTRAINT entitlement_units_pkey PRIMARY KEY (resource_id, unit, entitlement_id);


--
-- Name: entitlement_uses entitlement_uses_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_uses
    ADD CONSTRAINT entitlement_uses_pkey PRIMARY KEY (entitlement_id, occurrence_id);


--
-- Name: entitlements entitlements_coalesce_offer_id_in_effect_excl; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_coalesce_offer_id_in_effect_excl EXCLUDE USING gist (COALESCE(holder_user_id, holder_family_member_id, holder_tenant_id) WITH =, offer_id WITH =, in_effect WITH &&) WHERE ((plan_kind <> 'one_time'::text));


--
-- Name: entitlements entitlements_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: events events_project_id_location_id_time_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.events
    ADD CONSTRAINT events_project_id_location_id_time_key UNIQUE (project_id, location_id, "time");


--
-- Name: family_members family_members_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.family_members
    ADD CONSTRAINT family_members_pkey PRIMARY KEY (id);


--
-- Name: holds holds_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.holds
    ADD CONSTRAINT holds_pkey PRIMARY KEY (id);


--
-- Name: locations locations_name_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.locations
    ADD CONSTRAINT locations_name_key UNIQUE (name);


--
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id);


--
-- Name: locations locations_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.locations
    ADD CONSTRAINT locations_slug_key UNIQUE (slug);


--
-- Name: magic_link_tokens magic_link_tokens_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.magic_link_tokens
    ADD CONSTRAINT magic_link_tokens_pkey PRIMARY KEY (id);


--
-- Name: magic_link_tokens magic_link_tokens_token_hash_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.magic_link_tokens
    ADD CONSTRAINT magic_link_tokens_token_hash_key UNIQUE (token_hash);


--
-- Name: message_recipients message_recipients_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.message_recipients
    ADD CONSTRAINT message_recipients_pkey PRIMARY KEY (id);


--
-- Name: message_templates message_templates_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.message_templates
    ADD CONSTRAINT message_templates_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: offer_version_payment_plans offer_version_payment_plans_offer_version_id_id_kind_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_version_payment_plans
    ADD CONSTRAINT offer_version_payment_plans_offer_version_id_id_kind_key UNIQUE (offer_version_id, id, kind);


--
-- Name: offer_version_payment_plans offer_version_payment_plans_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_version_payment_plans
    ADD CONSTRAINT offer_version_payment_plans_pkey PRIMARY KEY (offer_version_id, id);


--
-- Name: offer_versions offer_versions_id_offer_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_versions
    ADD CONSTRAINT offer_versions_id_offer_id_key UNIQUE (id, offer_id);


--
-- Name: offer_versions offer_versions_offer_version_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_versions
    ADD CONSTRAINT offer_versions_offer_version_key UNIQUE (offer_id, version);


--
-- Name: offer_versions offer_versions_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_versions
    ADD CONSTRAINT offer_versions_pkey PRIMARY KEY (id);


--
-- Name: offers offers_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offers
    ADD CONSTRAINT offers_pkey PRIMARY KEY (id);


--
-- Name: outcome_definitions outcome_definitions_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.outcome_definitions
    ADD CONSTRAINT outcome_definitions_pkey PRIMARY KEY (id);


--
-- Name: passkeys passkeys_credential_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.passkeys
    ADD CONSTRAINT passkeys_credential_id_key UNIQUE (credential_id);


--
-- Name: passkeys passkeys_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.passkeys
    ADD CONSTRAINT passkeys_pkey PRIMARY KEY (id);


--
-- Name: payment_items payment_items_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payment_items
    ADD CONSTRAINT payment_items_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: platform_settings platform_settings_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.platform_settings
    ADD CONSTRAINT platform_settings_pkey PRIMARY KEY (key);


--
-- Name: pricing_plans pricing_plans_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_plans
    ADD CONSTRAINT pricing_plans_pkey PRIMARY KEY (id);


--
-- Name: program_types program_types_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.program_types
    ADD CONSTRAINT program_types_pkey PRIMARY KEY (id);


--
-- Name: program_types program_types_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.program_types
    ADD CONSTRAINT program_types_slug_key UNIQUE (slug);


--
-- Name: projects projects_name_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.projects
    ADD CONSTRAINT projects_name_key UNIQUE (name);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: projects projects_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.projects
    ADD CONSTRAINT projects_slug_key UNIQUE (slug);


--
-- Name: resources resources_event_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.resources
    ADD CONSTRAINT resources_event_id_key UNIQUE (event_id);


--
-- Name: resources resources_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.resources
    ADD CONSTRAINT resources_pkey PRIMARY KEY (id);


--
-- Name: session_events session_events_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_events
    ADD CONSTRAINT session_events_pkey PRIMARY KEY (id);


--
-- Name: session_events session_events_session_id_event_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_events
    ADD CONSTRAINT session_events_session_id_event_id_key UNIQUE (session_id, event_id);


--
-- Name: session_teachers session_teachers_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_teachers
    ADD CONSTRAINT session_teachers_pkey PRIMARY KEY (id);


--
-- Name: session_teachers session_teachers_session_id_teacher_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_teachers
    ADD CONSTRAINT session_teachers_session_id_teacher_id_key UNIQUE (session_id, teacher_id);


--
-- Name: sessions sessions_name_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.sessions
    ADD CONSTRAINT sessions_name_key UNIQUE (name);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.sessions
    ADD CONSTRAINT sessions_slug_key UNIQUE (slug);


--
-- Name: subscription_events subscription_events_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.subscription_events
    ADD CONSTRAINT subscription_events_pkey PRIMARY KEY (id);


--
-- Name: subscription_events subscription_events_stripe_event_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.subscription_events
    ADD CONSTRAINT subscription_events_stripe_event_id_key UNIQUE (stripe_event_id);


--
-- Name: templates templates_name_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.templates
    ADD CONSTRAINT templates_name_key UNIQUE (name);


--
-- Name: templates templates_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.templates
    ADD CONSTRAINT templates_pkey PRIMARY KEY (id);


--
-- Name: templates templates_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.templates
    ADD CONSTRAINT templates_slug_key UNIQUE (slug);


--
-- Name: tenant_domains tenant_domains_domain_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_domains
    ADD CONSTRAINT tenant_domains_domain_key UNIQUE (domain);


--
-- Name: tenant_domains tenant_domains_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_domains
    ADD CONSTRAINT tenant_domains_pkey PRIMARY KEY (id);


--
-- Name: tenant_profiles tenant_profiles_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_profiles
    ADD CONSTRAINT tenant_profiles_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenant_users tenant_users_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_users
    ADD CONSTRAINT tenant_users_pkey PRIMARY KEY (tenant_id, user_id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenants
    ADD CONSTRAINT tenants_slug_key UNIQUE (slug);


--
-- Name: transfer_requests transfer_requests_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.transfer_requests
    ADD CONSTRAINT transfer_requests_pkey PRIMARY KEY (id);


--
-- Name: user_preferences user_preferences_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.user_preferences
    ADD CONSTRAINT user_preferences_pkey PRIMARY KEY (id);


--
-- Name: user_preferences user_preferences_user_id_preference_key_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.user_preferences
    ADD CONSTRAINT user_preferences_user_id_preference_key_key UNIQUE (user_id, preference_key);


--
-- Name: user_profiles user_profiles_email_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.user_profiles
    ADD CONSTRAINT user_profiles_email_key UNIQUE (email);


--
-- Name: user_profiles user_profiles_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: waitlist waitlist_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.waitlist
    ADD CONSTRAINT waitlist_pkey PRIMARY KEY (id);


--
-- Name: waitlist waitlist_session_id_student_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.waitlist
    ADD CONSTRAINT waitlist_session_id_student_id_key UNIQUE (session_id, student_id);


--
-- Name: webhook_events webhook_events_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.webhook_events
    ADD CONSTRAINT webhook_events_pkey PRIMARY KEY (id);


--
-- Name: webhook_events webhook_events_stripe_event_id_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.webhook_events
    ADD CONSTRAINT webhook_events_stripe_event_id_key UNIQUE (stripe_event_id);


--
-- Name: workflow_runs workflow_runs_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_runs
    ADD CONSTRAINT workflow_runs_pkey PRIMARY KEY (id);


--
-- Name: workflow_steps workflow_steps_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_steps
    ADD CONSTRAINT workflow_steps_pkey PRIMARY KEY (id);


--
-- Name: workflow_steps workflow_steps_workflow_id_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_steps
    ADD CONSTRAINT workflow_steps_workflow_id_slug_key UNIQUE (workflow_id, slug);


--
-- Name: workflows workflows_name_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflows
    ADD CONSTRAINT workflows_name_key UNIQUE (name);


--
-- Name: workflows workflows_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflows
    ADD CONSTRAINT workflows_pkey PRIMARY KEY (id);


--
-- Name: workflows workflows_slug_key; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflows
    ADD CONSTRAINT workflows_slug_key UNIQUE (slug);


--
-- Name: changes changes_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.changes
    ADD CONSTRAINT changes_pkey PRIMARY KEY (change_id);


--
-- Name: changes changes_project_script_hash_key; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.changes
    ADD CONSTRAINT changes_project_script_hash_key UNIQUE (project, script_hash);


--
-- Name: dependencies dependencies_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.dependencies
    ADD CONSTRAINT dependencies_pkey PRIMARY KEY (change_id, dependency);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (change_id, committed_at);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (project);


--
-- Name: projects projects_uri_key; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.projects
    ADD CONSTRAINT projects_uri_key UNIQUE (uri);


--
-- Name: releases releases_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.releases
    ADD CONSTRAINT releases_pkey PRIMARY KEY (version);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (tag_id);


--
-- Name: tags tags_project_tag_key; Type: CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.tags
    ADD CONSTRAINT tags_project_tag_key UNIQUE (project, tag);


--
-- Name: enrollments_payment_dedup; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX enrollments_payment_dedup ON registry.enrollments USING btree (session_id, student_id, payment_id) WHERE (payment_id IS NOT NULL);


--
-- Name: enrollments_session_student_type_live; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX enrollments_session_student_type_live ON registry.enrollments USING btree (session_id, student_id, student_type) WHERE (status IS DISTINCT FROM 'cancelled'::text);


--
-- Name: idx_api_keys_key_hash; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_api_keys_key_hash ON registry.api_keys USING btree (key_hash);


--
-- Name: idx_api_keys_user_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_api_keys_user_id ON registry.api_keys USING btree (user_id);


--
-- Name: idx_attendance_event_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_attendance_event_id ON registry.attendance_records USING btree (event_id);


--
-- Name: idx_attendance_event_student; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_attendance_event_student ON registry.attendance_records USING btree (event_id, student_id);


--
-- Name: idx_attendance_family_member_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_attendance_family_member_id ON registry.attendance_records USING btree (family_member_id);


--
-- Name: idx_attendance_marked_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_attendance_marked_at ON registry.attendance_records USING btree (marked_at);


--
-- Name: idx_attendance_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_attendance_status ON registry.attendance_records USING btree (status);


--
-- Name: idx_attendance_student_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_attendance_student_id ON registry.attendance_records USING btree (student_id);


--
-- Name: idx_drop_requests_enrollment_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_drop_requests_enrollment_id ON registry.drop_requests USING btree (enrollment_id);


--
-- Name: idx_drop_requests_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_drop_requests_status ON registry.drop_requests USING btree (status);


--
-- Name: idx_enrollments_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_created_at ON registry.enrollments USING btree (created_at);


--
-- Name: idx_enrollments_dashboard; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_dashboard ON registry.enrollments USING btree (status, created_at) WHERE (status = ANY (ARRAY['active'::text, 'pending'::text]));


--
-- Name: idx_enrollments_drop_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_drop_status ON registry.enrollments USING btree (status) WHERE (drop_reason IS NOT NULL);


--
-- Name: idx_enrollments_family_member_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_family_member_id ON registry.enrollments USING btree (family_member_id);


--
-- Name: idx_enrollments_parent_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_parent_id ON registry.enrollments USING btree (parent_id);


--
-- Name: idx_enrollments_payment_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_payment_id ON registry.enrollments USING btree (payment_id);


--
-- Name: idx_enrollments_session_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_session_id ON registry.enrollments USING btree (session_id);


--
-- Name: idx_enrollments_session_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_session_status ON registry.enrollments USING btree (session_id, status);


--
-- Name: idx_enrollments_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_status ON registry.enrollments USING btree (status);


--
-- Name: idx_enrollments_student_type; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_enrollments_student_type ON registry.enrollments USING btree (student_type);


--
-- Name: idx_events_location_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_events_location_id ON registry.events USING btree (location_id);


--
-- Name: idx_events_project_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_events_project_id ON registry.events USING btree (project_id);


--
-- Name: idx_events_teacher_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_events_teacher_id ON registry.events USING btree (teacher_id);


--
-- Name: idx_events_time; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_events_time ON registry.events USING btree ("time");


--
-- Name: idx_family_members_birth_date; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_family_members_birth_date ON registry.family_members USING btree (birth_date);


--
-- Name: idx_family_members_family_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_family_members_family_id ON registry.family_members USING btree (family_id);


--
-- Name: idx_family_members_name; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_family_members_name ON registry.family_members USING btree (child_name);


--
-- Name: idx_locations_contact_person; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_locations_contact_person ON registry.locations USING btree (contact_person_id);


--
-- Name: idx_magic_link_tokens_token_hash; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_magic_link_tokens_token_hash ON registry.magic_link_tokens USING btree (token_hash);


--
-- Name: idx_magic_link_tokens_user_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_magic_link_tokens_user_id ON registry.magic_link_tokens USING btree (user_id);


--
-- Name: idx_message_recipients_message_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_message_recipients_message_id ON registry.message_recipients USING btree (message_id);


--
-- Name: idx_message_recipients_read_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_message_recipients_read_at ON registry.message_recipients USING btree (read_at) WHERE (read_at IS NULL);


--
-- Name: idx_message_recipients_recipient_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_message_recipients_recipient_id ON registry.message_recipients USING btree (recipient_id);


--
-- Name: idx_message_recipients_unread; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_message_recipients_unread ON registry.message_recipients USING btree (recipient_id, read_at) WHERE (read_at IS NULL);


--
-- Name: idx_message_templates_active; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_message_templates_active ON registry.message_templates USING btree (is_active) WHERE (is_active = true);


--
-- Name: idx_message_templates_scope; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_message_templates_scope ON registry.message_templates USING btree (scope);


--
-- Name: idx_message_templates_type; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_message_templates_type ON registry.message_templates USING btree (message_type);


--
-- Name: idx_messages_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_created_at ON registry.messages USING btree (created_at);


--
-- Name: idx_messages_scheduled; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_scheduled ON registry.messages USING btree (scheduled_for) WHERE (scheduled_for IS NOT NULL);


--
-- Name: idx_messages_scheduled_for; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_scheduled_for ON registry.messages USING btree (scheduled_for) WHERE (scheduled_for IS NOT NULL);


--
-- Name: idx_messages_scope; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_scope ON registry.messages USING btree (scope, scope_id);


--
-- Name: idx_messages_sender_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_sender_id ON registry.messages USING btree (sender_id);


--
-- Name: idx_messages_sent; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_sent ON registry.messages USING btree (sent_at) WHERE (sent_at IS NOT NULL);


--
-- Name: idx_messages_sent_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_sent_at ON registry.messages USING btree (sent_at);


--
-- Name: idx_messages_type; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_type ON registry.messages USING btree (message_type);


--
-- Name: idx_messages_unread; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_messages_unread ON registry.message_recipients USING btree (recipient_id, message_id) WHERE (read_at IS NULL);


--
-- Name: idx_notifications_channel; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_channel ON registry.notifications USING btree (channel);


--
-- Name: idx_notifications_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_created_at ON registry.notifications USING btree (created_at);


--
-- Name: idx_notifications_failed_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_failed_at ON registry.notifications USING btree (failed_at);


--
-- Name: idx_notifications_pending; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_pending ON registry.notifications USING btree (created_at, user_id) WHERE (sent_at IS NULL);


--
-- Name: idx_notifications_read_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_read_at ON registry.notifications USING btree (read_at);


--
-- Name: idx_notifications_sent_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_sent_at ON registry.notifications USING btree (sent_at);


--
-- Name: idx_notifications_type; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_type ON registry.notifications USING btree (type);


--
-- Name: idx_notifications_user_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_notifications_user_id ON registry.notifications USING btree (user_id);


--
-- Name: idx_passkeys_credential_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_passkeys_credential_id ON registry.passkeys USING btree (credential_id);


--
-- Name: idx_passkeys_user_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_passkeys_user_id ON registry.passkeys USING btree (user_id);


--
-- Name: idx_payment_items_payment_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payment_items_payment_id ON registry.payment_items USING btree (payment_id);


--
-- Name: idx_payments_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_created_at ON registry.payments USING btree (created_at);


--
-- Name: idx_payments_instalment_set; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_instalment_set ON registry.payments USING btree (stripe_schedule_id, instalment_seq) WHERE (stripe_schedule_id IS NOT NULL);


--
-- Name: idx_payments_instalments_due; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_instalments_due ON registry.payments USING btree (due_date) WHERE ((instalment_seq IS NOT NULL) AND ((status)::text = ANY ((ARRAY['pending'::character varying, 'failed'::character varying])::text[])));


--
-- Name: idx_payments_platform_fee; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_platform_fee ON registry.payments USING btree (platform_offer_version_id) WHERE (platform_fee_cents IS NOT NULL);


--
-- Name: idx_payments_refund_owed; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_refund_owed ON registry.payments USING btree (refund_owed_cents) WHERE (refund_owed_cents > 0);


--
-- Name: idx_payments_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_status ON registry.payments USING btree (status);


--
-- Name: idx_payments_stripe_intent; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_stripe_intent ON registry.payments USING btree (stripe_payment_intent_id);


--
-- Name: idx_payments_user_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_user_id ON registry.payments USING btree (user_id);


--
-- Name: idx_projects_name; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_projects_name ON registry.projects USING btree (name);


--
-- Name: idx_projects_program_type; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_projects_program_type ON registry.projects USING btree (program_type_slug);


--
-- Name: idx_projects_slug; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_projects_slug ON registry.projects USING btree (slug);


--
-- Name: idx_session_teachers_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_session_teachers_created_at ON registry.session_teachers USING btree (created_at);


--
-- Name: idx_session_teachers_session_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_session_teachers_session_id ON registry.session_teachers USING btree (session_id);


--
-- Name: idx_session_teachers_teacher_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_session_teachers_teacher_id ON registry.session_teachers USING btree (teacher_id);


--
-- Name: idx_sessions_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_sessions_created_at ON registry.sessions USING btree (created_at);


--
-- Name: idx_sessions_name; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_sessions_name ON registry.sessions USING btree (name);


--
-- Name: idx_sessions_slug; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_sessions_slug ON registry.sessions USING btree (slug);


--
-- Name: idx_subscription_events_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_subscription_events_status ON registry.subscription_events USING btree (processing_status);


--
-- Name: idx_subscription_events_tenant; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_subscription_events_tenant ON registry.subscription_events USING btree (tenant_id);


--
-- Name: idx_tenant_domains_domain; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_tenant_domains_domain ON registry.tenant_domains USING btree (domain);


--
-- Name: idx_tenant_domains_primary; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX idx_tenant_domains_primary ON registry.tenant_domains USING btree (tenant_id) WHERE (is_primary = true);


--
-- Name: idx_tenant_domains_tenant_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_tenant_domains_tenant_id ON registry.tenant_domains USING btree (tenant_id);


--
-- Name: idx_tenants_billing_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_tenants_billing_status ON registry.tenants USING btree (billing_status);


--
-- Name: idx_tenants_created_from_ip_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_tenants_created_from_ip_created_at ON registry.tenants USING btree (created_from_ip, created_at);


--
-- Name: idx_tenants_stripe_customer; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_tenants_stripe_customer ON registry.tenants USING btree (stripe_customer_id);


--
-- Name: idx_tenants_stripe_subscription; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_tenants_stripe_subscription ON registry.tenants USING btree (stripe_subscription_id);


--
-- Name: idx_transfer_requests_enrollment_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_transfer_requests_enrollment_id ON registry.transfer_requests USING btree (enrollment_id);


--
-- Name: idx_transfer_requests_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_transfer_requests_status ON registry.transfer_requests USING btree (status);


--
-- Name: idx_user_preferences_key; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_user_preferences_key ON registry.user_preferences USING btree (preference_key);


--
-- Name: idx_user_preferences_preference_key; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_user_preferences_preference_key ON registry.user_preferences USING btree (preference_key);


--
-- Name: idx_user_preferences_user_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_user_preferences_user_id ON registry.user_preferences USING btree (user_id);


--
-- Name: idx_user_preferences_user_key; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_user_preferences_user_key ON registry.user_preferences USING btree (user_id, preference_key);


--
-- Name: idx_user_profiles_email; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_user_profiles_email ON registry.user_profiles USING btree (email);


--
-- Name: idx_user_profiles_user_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_user_profiles_user_id ON registry.user_profiles USING btree (user_id);


--
-- Name: idx_users_deactivated_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_users_deactivated_at ON registry.users USING btree (deactivated_at) WHERE (deactivated_at IS NOT NULL);


--
-- Name: idx_waitlist_active; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_active ON registry.waitlist USING btree (session_id, "position") WHERE (status = ANY (ARRAY['waiting'::text, 'offered'::text]));


--
-- Name: idx_waitlist_expires_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_expires_at ON registry.waitlist USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: idx_waitlist_family_member_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_family_member_id ON registry.waitlist USING btree (family_member_id);


--
-- Name: idx_waitlist_parent_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_parent_id ON registry.waitlist USING btree (parent_id);


--
-- Name: idx_waitlist_position; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_position ON registry.waitlist USING btree (session_id, "position");


--
-- Name: idx_waitlist_session_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_session_id ON registry.waitlist USING btree (session_id);


--
-- Name: idx_waitlist_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_status ON registry.waitlist USING btree (status);


--
-- Name: idx_waitlist_student_id; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_waitlist_student_id ON registry.waitlist USING btree (student_id);


--
-- Name: location_address_gin; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX location_address_gin ON registry.locations USING gin (address_info);


--
-- Name: offer_versions_one_current_per_offer; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX offer_versions_one_current_per_offer ON registry.offer_versions USING btree (offer_id) WHERE ((published_at IS NOT NULL) AND (superseded_at IS NULL));


--
-- Name: payment_items_pricing_plan_id_idx; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX payment_items_pricing_plan_id_idx ON registry.payment_items USING btree (pricing_plan_id) WHERE (pricing_plan_id IS NOT NULL);


--
-- Name: pricing_plans_family_version_key; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX pricing_plans_family_version_key ON registry.pricing_plans USING btree (plan_family_id, version);


--
-- Name: pricing_plans_one_current_per_family; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX pricing_plans_one_current_per_family ON registry.pricing_plans USING btree (plan_family_id) WHERE (superseded_at IS NULL);


--
-- Name: tenants_stripe_connect_account_id_key; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX tenants_stripe_connect_account_id_key ON registry.tenants USING btree (stripe_connect_account_id) WHERE (stripe_connect_account_id IS NOT NULL);


--
-- Name: entitlements entitlement_holder_is_offerer; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER entitlement_holder_is_offerer BEFORE INSERT OR UPDATE ON registry.entitlements FOR EACH ROW EXECUTE FUNCTION registry.entitlement_holder_is_offerer();


--
-- Name: entitlements entitlement_one_platform_term; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER entitlement_one_platform_term BEFORE INSERT OR UPDATE ON registry.entitlements FOR EACH ROW EXECUTE FUNCTION registry.entitlement_one_platform_term();


--
-- Name: entitlements entitlements_stamp; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER entitlements_stamp BEFORE INSERT OR UPDATE ON registry.entitlements FOR EACH ROW EXECUTE FUNCTION registry.entitlement_stamp();


--
-- Name: offer_version_payment_plans offer_version_payment_plans_immutable; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER offer_version_payment_plans_immutable BEFORE INSERT OR DELETE OR UPDATE ON registry.offer_version_payment_plans FOR EACH ROW EXECUTE FUNCTION registry.offer_version_payment_plan_immutable();


--
-- Name: offer_versions offer_versions_immutable; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER offer_versions_immutable BEFORE DELETE OR UPDATE ON registry.offer_versions FOR EACH ROW EXECUTE FUNCTION registry.offer_version_immutable();


--
-- Name: offer_versions offer_versions_keep_platform_offer; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE CONSTRAINT TRIGGER offer_versions_keep_platform_offer AFTER UPDATE OF superseded_at ON registry.offer_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (((old.superseded_at IS NULL) AND (new.superseded_at IS NOT NULL))) EXECUTE FUNCTION registry.offer_versions_keep_platform_offer();


--
-- Name: offer_versions offer_versions_require_payment_plan; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE CONSTRAINT TRIGGER offer_versions_require_payment_plan AFTER INSERT OR UPDATE OF published_at ON registry.offer_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION registry.offer_version_requires_payment_plan();


--
-- Name: payments payments_offer_version_stamp; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER payments_offer_version_stamp BEFORE UPDATE OF offer_version_id ON registry.payments FOR EACH ROW EXECUTE FUNCTION registry.payment_offer_version_stamp();


--
-- Name: pricing_plans pricing_plans_family_default; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER pricing_plans_family_default BEFORE INSERT ON registry.pricing_plans FOR EACH ROW EXECUTE FUNCTION registry.pricing_plan_family_default();


--
-- Name: pricing_plans pricing_plans_terms_immutable; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER pricing_plans_terms_immutable BEFORE UPDATE ON registry.pricing_plans FOR EACH ROW EXECUTE FUNCTION registry.pricing_plan_terms_immutable();


--
-- Name: resources resources_keep_platform_offer_name; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER resources_keep_platform_offer_name AFTER UPDATE OF name ON registry.resources FOR EACH ROW WHEN (((old.name = 'payment processing'::text) AND (new.name IS DISTINCT FROM old.name))) EXECUTE FUNCTION registry.resources_keep_platform_offer_name();


--
-- Name: tenant_domains tenant_domains_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER tenant_domains_updated_at BEFORE UPDATE ON registry.tenant_domains FOR EACH ROW EXECUTE FUNCTION registry.tenant_domains_updated_at();


--
-- Name: attendance_records update_attendance_records_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_attendance_records_updated_at BEFORE UPDATE ON registry.attendance_records FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: family_members update_family_members_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_family_members_updated_at BEFORE UPDATE ON registry.family_members FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: message_templates update_message_templates_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_message_templates_updated_at BEFORE UPDATE ON registry.message_templates FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: messages update_messages_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_messages_updated_at BEFORE UPDATE ON registry.messages FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: notifications update_notifications_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_notifications_updated_at BEFORE UPDATE ON registry.notifications FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: payments update_payments_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_payments_updated_at BEFORE UPDATE ON registry.payments FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: program_types update_program_types_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_program_types_updated_at BEFORE UPDATE ON registry.program_types FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: user_preferences update_user_preferences_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_user_preferences_updated_at BEFORE UPDATE ON registry.user_preferences FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: waitlist update_waitlist_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_waitlist_updated_at BEFORE UPDATE ON registry.waitlist FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: api_keys api_keys_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.api_keys
    ADD CONSTRAINT api_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id) ON DELETE CASCADE;


--
-- Name: attendance_records attendance_records_event_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.attendance_records
    ADD CONSTRAINT attendance_records_event_id_fkey FOREIGN KEY (event_id) REFERENCES registry.events(id);


--
-- Name: attendance_records attendance_records_family_member_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.attendance_records
    ADD CONSTRAINT attendance_records_family_member_id_fkey FOREIGN KEY (family_member_id) REFERENCES registry.family_members(id);


--
-- Name: attendance_records attendance_records_marked_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.attendance_records
    ADD CONSTRAINT attendance_records_marked_by_fkey FOREIGN KEY (marked_by) REFERENCES registry.users(id);


--
-- Name: drop_requests drop_requests_enrollment_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.drop_requests
    ADD CONSTRAINT drop_requests_enrollment_id_fkey FOREIGN KEY (enrollment_id) REFERENCES registry.enrollments(id);


--
-- Name: drop_requests drop_requests_processed_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.drop_requests
    ADD CONSTRAINT drop_requests_processed_by_fkey FOREIGN KEY (processed_by) REFERENCES registry.users(id);


--
-- Name: drop_requests drop_requests_requested_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.drop_requests
    ADD CONSTRAINT drop_requests_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES registry.users(id);


--
-- Name: enrollments enrollments_dropped_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_dropped_by_fkey FOREIGN KEY (dropped_by) REFERENCES registry.users(id);


--
-- Name: enrollments enrollments_family_member_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_family_member_id_fkey FOREIGN KEY (family_member_id) REFERENCES registry.family_members(id);


--
-- Name: enrollments enrollments_parent_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES registry.users(id);


--
-- Name: enrollments enrollments_payment_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES registry.payments(id);


--
-- Name: enrollments enrollments_session_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_session_id_fkey FOREIGN KEY (session_id) REFERENCES registry.sessions(id);


--
-- Name: enrollments enrollments_transfer_to_session_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_transfer_to_session_id_fkey FOREIGN KEY (transfer_to_session_id) REFERENCES registry.sessions(id);


--
-- Name: entitlement_refunds entitlement_refunds_entitlement_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_refunds
    ADD CONSTRAINT entitlement_refunds_entitlement_id_fkey FOREIGN KEY (entitlement_id) REFERENCES registry.entitlements(id);


--
-- Name: entitlement_units entitlement_units_entitlement_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_units
    ADD CONSTRAINT entitlement_units_entitlement_id_fkey FOREIGN KEY (entitlement_id) REFERENCES registry.entitlements(id);


--
-- Name: entitlement_units entitlement_units_resource_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_units
    ADD CONSTRAINT entitlement_units_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES registry.resources(id);


--
-- Name: entitlement_uses entitlement_uses_entitlement_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_uses
    ADD CONSTRAINT entitlement_uses_entitlement_id_fkey FOREIGN KEY (entitlement_id) REFERENCES registry.entitlements(id);


--
-- Name: entitlement_uses entitlement_uses_occurrence_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_uses
    ADD CONSTRAINT entitlement_uses_occurrence_id_fkey FOREIGN KEY (occurrence_id) REFERENCES registry.resources(id);


--
-- Name: entitlement_uses entitlement_uses_recorded_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlement_uses
    ADD CONSTRAINT entitlement_uses_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES registry.users(id);


--
-- Name: entitlements entitlements_holder_family_member_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_holder_family_member_id_fkey FOREIGN KEY (holder_family_member_id) REFERENCES registry.family_members(id);


--
-- Name: entitlements entitlements_holder_tenant_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_holder_tenant_id_fkey FOREIGN KEY (holder_tenant_id) REFERENCES registry.tenants(id);


--
-- Name: entitlements entitlements_holder_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_holder_user_id_fkey FOREIGN KEY (holder_user_id) REFERENCES registry.users(id);


--
-- Name: entitlements entitlements_offer_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_offer_fkey FOREIGN KEY (offer_version_id, offer_id) REFERENCES registry.offer_versions(id, offer_id);


--
-- Name: entitlements entitlements_payer_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_payer_user_id_fkey FOREIGN KEY (payer_user_id) REFERENCES registry.users(id);


--
-- Name: entitlements entitlements_payment_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES registry.payments(id);


--
-- Name: entitlements entitlements_payment_plan_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.entitlements
    ADD CONSTRAINT entitlements_payment_plan_fkey FOREIGN KEY (offer_version_id, payment_plan_id, plan_kind) REFERENCES registry.offer_version_payment_plans(offer_version_id, id, kind) MATCH FULL;


--
-- Name: events events_location_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.events
    ADD CONSTRAINT events_location_id_fkey FOREIGN KEY (location_id) REFERENCES registry.locations(id);


--
-- Name: events events_project_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.events
    ADD CONSTRAINT events_project_id_fkey FOREIGN KEY (project_id) REFERENCES registry.projects(id);


--
-- Name: events events_teacher_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.events
    ADD CONSTRAINT events_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES registry.users(id);


--
-- Name: family_members family_members_family_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.family_members
    ADD CONSTRAINT family_members_family_id_fkey FOREIGN KEY (family_id) REFERENCES registry.users(id);


--
-- Name: projects fk_projects_program_type; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.projects
    ADD CONSTRAINT fk_projects_program_type FOREIGN KEY (program_type_slug) REFERENCES registry.program_types(slug);


--
-- Name: holds holds_resource_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.holds
    ADD CONSTRAINT holds_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES registry.resources(id);


--
-- Name: holds holds_workflow_run_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.holds
    ADD CONSTRAINT holds_workflow_run_id_fkey FOREIGN KEY (workflow_run_id) REFERENCES registry.workflow_runs(id);


--
-- Name: locations locations_contact_person_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.locations
    ADD CONSTRAINT locations_contact_person_id_fkey FOREIGN KEY (contact_person_id) REFERENCES registry.users(id);


--
-- Name: magic_link_tokens magic_link_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.magic_link_tokens
    ADD CONSTRAINT magic_link_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id) ON DELETE CASCADE;


--
-- Name: message_recipients message_recipients_message_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.message_recipients
    ADD CONSTRAINT message_recipients_message_id_fkey FOREIGN KEY (message_id) REFERENCES registry.messages(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id);


--
-- Name: offer_version_payment_plans offer_version_payment_plans_offer_version_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_version_payment_plans
    ADD CONSTRAINT offer_version_payment_plans_offer_version_id_fkey FOREIGN KEY (offer_version_id) REFERENCES registry.offer_versions(id) ON DELETE CASCADE;


--
-- Name: offer_versions offer_versions_class_project_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_versions
    ADD CONSTRAINT offer_versions_class_project_id_fkey FOREIGN KEY (class_project_id) REFERENCES registry.projects(id);


--
-- Name: offer_versions offer_versions_offer_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_versions
    ADD CONSTRAINT offer_versions_offer_id_fkey FOREIGN KEY (offer_id) REFERENCES registry.offers(id);


--
-- Name: offer_versions offer_versions_resource_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.offer_versions
    ADD CONSTRAINT offer_versions_resource_id_fkey FOREIGN KEY (resource_id) REFERENCES registry.resources(id);


--
-- Name: passkeys passkeys_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.passkeys
    ADD CONSTRAINT passkeys_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id) ON DELETE CASCADE;


--
-- Name: payment_items payment_items_payment_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payment_items
    ADD CONSTRAINT payment_items_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES registry.payments(id) ON DELETE CASCADE;


--
-- Name: payments payments_offer_version_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payments
    ADD CONSTRAINT payments_offer_version_id_fkey FOREIGN KEY (offer_version_id) REFERENCES registry.offer_versions(id);


--
-- Name: payments payments_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payments
    ADD CONSTRAINT payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id);


--
-- Name: platform_settings platform_settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.platform_settings
    ADD CONSTRAINT platform_settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES registry.users(id);


--
-- Name: resources resources_event_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.resources
    ADD CONSTRAINT resources_event_id_fkey FOREIGN KEY (event_id) REFERENCES registry.events(id);


--
-- Name: session_events session_events_event_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_events
    ADD CONSTRAINT session_events_event_id_fkey FOREIGN KEY (event_id) REFERENCES registry.events(id);


--
-- Name: session_events session_events_session_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_events
    ADD CONSTRAINT session_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES registry.sessions(id);


--
-- Name: session_teachers session_teachers_session_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_teachers
    ADD CONSTRAINT session_teachers_session_id_fkey FOREIGN KEY (session_id) REFERENCES registry.sessions(id);


--
-- Name: session_teachers session_teachers_teacher_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.session_teachers
    ADD CONSTRAINT session_teachers_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES registry.users(id);


--
-- Name: subscription_events subscription_events_tenant_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.subscription_events
    ADD CONSTRAINT subscription_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES registry.tenants(id);


--
-- Name: tenant_domains tenant_domains_tenant_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_domains
    ADD CONSTRAINT tenant_domains_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES registry.tenants(id) ON DELETE CASCADE;


--
-- Name: tenant_profiles tenant_profiles_tenant_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_profiles
    ADD CONSTRAINT tenant_profiles_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES registry.tenants(id);


--
-- Name: tenant_users tenant_users_tenant_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_users
    ADD CONSTRAINT tenant_users_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES registry.tenants(id);


--
-- Name: tenant_users tenant_users_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.tenant_users
    ADD CONSTRAINT tenant_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id);


--
-- Name: transfer_requests transfer_requests_enrollment_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.transfer_requests
    ADD CONSTRAINT transfer_requests_enrollment_id_fkey FOREIGN KEY (enrollment_id) REFERENCES registry.enrollments(id);


--
-- Name: transfer_requests transfer_requests_processed_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.transfer_requests
    ADD CONSTRAINT transfer_requests_processed_by_fkey FOREIGN KEY (processed_by) REFERENCES registry.users(id);


--
-- Name: transfer_requests transfer_requests_requested_by_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.transfer_requests
    ADD CONSTRAINT transfer_requests_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES registry.users(id);


--
-- Name: transfer_requests transfer_requests_target_session_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.transfer_requests
    ADD CONSTRAINT transfer_requests_target_session_id_fkey FOREIGN KEY (target_session_id) REFERENCES registry.sessions(id);


--
-- Name: user_preferences user_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.user_preferences
    ADD CONSTRAINT user_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id);


--
-- Name: user_profiles user_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.user_profiles
    ADD CONSTRAINT user_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id);


--
-- Name: waitlist waitlist_family_member_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.waitlist
    ADD CONSTRAINT waitlist_family_member_id_fkey FOREIGN KEY (family_member_id) REFERENCES registry.family_members(id);


--
-- Name: waitlist waitlist_location_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.waitlist
    ADD CONSTRAINT waitlist_location_id_fkey FOREIGN KEY (location_id) REFERENCES registry.locations(id);


--
-- Name: waitlist waitlist_parent_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.waitlist
    ADD CONSTRAINT waitlist_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES registry.users(id);


--
-- Name: waitlist waitlist_session_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.waitlist
    ADD CONSTRAINT waitlist_session_id_fkey FOREIGN KEY (session_id) REFERENCES registry.sessions(id);


--
-- Name: webhook_events webhook_events_tenant_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.webhook_events
    ADD CONSTRAINT webhook_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES registry.tenants(id) ON DELETE SET NULL;


--
-- Name: workflow_runs workflow_runs_continuation_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_runs
    ADD CONSTRAINT workflow_runs_continuation_id_fkey FOREIGN KEY (continuation_id) REFERENCES registry.workflow_runs(id);


--
-- Name: workflow_runs workflow_runs_latest_step_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_runs
    ADD CONSTRAINT workflow_runs_latest_step_id_fkey FOREIGN KEY (latest_step_id) REFERENCES registry.workflow_steps(id);


--
-- Name: workflow_runs workflow_runs_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_runs
    ADD CONSTRAINT workflow_runs_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id);


--
-- Name: workflow_runs workflow_runs_workflow_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_runs
    ADD CONSTRAINT workflow_runs_workflow_id_fkey FOREIGN KEY (workflow_id) REFERENCES registry.workflows(id);


--
-- Name: workflow_steps workflow_steps_depends_on_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_steps
    ADD CONSTRAINT workflow_steps_depends_on_fkey FOREIGN KEY (depends_on) REFERENCES registry.workflow_steps(id) ON UPDATE SET NULL ON DELETE CASCADE;


--
-- Name: workflow_steps workflow_steps_outcome_definition_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_steps
    ADD CONSTRAINT workflow_steps_outcome_definition_id_fkey FOREIGN KEY (outcome_definition_id) REFERENCES registry.outcome_definitions(id);


--
-- Name: workflow_steps workflow_steps_template_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_steps
    ADD CONSTRAINT workflow_steps_template_id_fkey FOREIGN KEY (template_id) REFERENCES registry.templates(id);


--
-- Name: workflow_steps workflow_steps_workflow_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.workflow_steps
    ADD CONSTRAINT workflow_steps_workflow_id_fkey FOREIGN KEY (workflow_id) REFERENCES registry.workflows(id);


--
-- Name: changes changes_project_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.changes
    ADD CONSTRAINT changes_project_fkey FOREIGN KEY (project) REFERENCES sqitch.projects(project) ON UPDATE CASCADE;


--
-- Name: dependencies dependencies_change_id_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.dependencies
    ADD CONSTRAINT dependencies_change_id_fkey FOREIGN KEY (change_id) REFERENCES sqitch.changes(change_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: dependencies dependencies_dependency_id_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.dependencies
    ADD CONSTRAINT dependencies_dependency_id_fkey FOREIGN KEY (dependency_id) REFERENCES sqitch.changes(change_id) ON UPDATE CASCADE;


--
-- Name: events events_project_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.events
    ADD CONSTRAINT events_project_fkey FOREIGN KEY (project) REFERENCES sqitch.projects(project) ON UPDATE CASCADE;


--
-- Name: tags tags_change_id_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.tags
    ADD CONSTRAINT tags_change_id_fkey FOREIGN KEY (change_id) REFERENCES sqitch.changes(change_id) ON UPDATE CASCADE;


--
-- Name: tags tags_project_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: postgres
--

ALTER TABLE ONLY sqitch.tags
    ADD CONSTRAINT tags_project_fkey FOREIGN KEY (project) REFERENCES sqitch.projects(project) ON UPDATE CASCADE;


--
-- PostgreSQL database dump complete
--


