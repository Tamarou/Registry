--
-- PostgreSQL database dump
--

\restrict WOMXCiW80QCJ1SV6ZxzPz9eboREUCg1Yybw2PyhorzWbeSbb4SiWiId63ZuJh0Q

-- Dumped from database version 18.3 (Ubuntu 18.3-1.pgdg22.04+1)
-- Dumped by pg_dump version 18.3 (Ubuntu 18.3-1.pgdg22.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
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
    'message_emergency'
);


ALTER TYPE registry.notification_type OWNER TO postgres;

--
-- Name: ensure_event_sequence(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.ensure_event_sequence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_last_sequence BIGINT;
    v_expected_version INTEGER;
BEGIN
    -- Get the last sequence number for this relationship
    SELECT COALESCE(MAX(sequence_number), 0)
    INTO v_last_sequence
    FROM registry.pricing_relationship_events
    WHERE relationship_id = NEW.relationship_id
    AND id != NEW.id;

    -- Get expected aggregate version
    v_expected_version := get_next_aggregate_version(NEW.relationship_id);

    -- Verify aggregate version matches
    IF NEW.aggregate_version != v_expected_version THEN
        RAISE EXCEPTION 'Aggregate version mismatch. Expected %, got %',
            v_expected_version, NEW.aggregate_version;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.ensure_event_sequence() OWNER TO postgres;

--
-- Name: get_next_aggregate_version(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_next_aggregate_version(p_relationship_id uuid) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_version INTEGER;
BEGIN
    SELECT COALESCE(MAX(aggregate_version), 0) + 1
    INTO v_version
    FROM registry.pricing_relationship_events
    WHERE relationship_id = p_relationship_id;

    RETURN v_version;
END;
$$;


ALTER FUNCTION public.get_next_aggregate_version(p_relationship_id uuid) OWNER TO postgres;

--
-- Name: get_relationship_state_at(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_relationship_state_at(p_relationship_id uuid, p_timestamp timestamp with time zone) RETURNS TABLE(relationship_id uuid, status text, pricing_plan_id uuid, metadata jsonb, last_event_type text, last_event_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH events_before AS (
        SELECT
            event_type,
            event_data,
            occurred_at
        FROM registry.pricing_relationship_events pre
        WHERE pre.relationship_id = p_relationship_id
        AND pre.occurred_at <= p_timestamp
        ORDER BY pre.sequence_number DESC
        LIMIT 1
    ),
    base_relationship AS (
        SELECT
            pr.id,
            pr.pricing_plan_id as original_plan_id,
            pr.metadata as original_metadata
        FROM registry.pricing_relationships pr
        WHERE pr.id = p_relationship_id
    )
    SELECT
        br.id as relationship_id,
        CASE
            WHEN eb.event_type = 'terminated' THEN 'cancelled'
            WHEN eb.event_type = 'suspended' THEN 'suspended'
            WHEN eb.event_type IN ('activated', 'created') THEN 'active'
            ELSE 'unknown'
        END as status,
        COALESCE((eb.event_data->>'new_plan_id')::UUID, br.original_plan_id) as pricing_plan_id,
        COALESCE(eb.event_data->'new_metadata', br.original_metadata) as metadata,
        eb.event_type as last_event_type,
        eb.occurred_at as last_event_at
    FROM base_relationship br
    LEFT JOIN events_before eb ON true;
END;
$$;


ALTER FUNCTION public.get_relationship_state_at(p_relationship_id uuid, p_timestamp timestamp with time zone) OWNER TO postgres;

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
$_$;


ALTER FUNCTION registry.copy_workflow(dest_schema text, workflow_id uuid, source_schema text) OWNER TO postgres;

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
-- Name: billing_periods; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.billing_periods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    calculated_amount numeric(10,2) NOT NULL,
    payment_status character varying(50) DEFAULT 'pending'::character varying,
    stripe_invoice_id character varying(255),
    stripe_payment_intent_id character varying(255),
    processed_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    pricing_relationship_id uuid NOT NULL,
    CONSTRAINT billing_periods_payment_status_check CHECK (((payment_status)::text = ANY ((ARRAY['pending'::character varying, 'processing'::character varying, 'paid'::character varying, 'failed'::character varying, 'refunded'::character varying])::text[])))
);


ALTER TABLE registry.billing_periods OWNER TO postgres;

--
-- Name: drop_requests; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.drop_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    enrollment_id uuid NOT NULL,
    requested_by uuid NOT NULL,
    reason text NOT NULL,
    refund_requested boolean DEFAULT false,
    refund_amount_requested numeric(10,2),
    status text DEFAULT 'pending'::text,
    admin_notes text,
    processed_by uuid,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
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
    refund_amount numeric(10,2),
    transfer_to_session_id uuid,
    transfer_status text DEFAULT 'none'::text,
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
-- Name: COLUMN enrollments.refund_amount; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.refund_amount IS 'Amount refunded for dropped enrollment';


--
-- Name: COLUMN enrollments.transfer_to_session_id; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.transfer_to_session_id IS 'Target session if enrollment was transferred';


--
-- Name: COLUMN enrollments.transfer_status; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.enrollments.transfer_status IS 'Status of transfer processing';


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
    amount numeric(10,2) NOT NULL,
    quantity integer DEFAULT 1,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE registry.payment_items OWNER TO postgres;

--
-- Name: payment_schedules; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.payment_schedules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    enrollment_id uuid NOT NULL,
    pricing_plan_id uuid NOT NULL,
    stripe_subscription_id character varying(255),
    total_amount numeric(10,2) NOT NULL,
    installment_amount numeric(10,2) NOT NULL,
    installment_count integer NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT check_installment_amount CHECK ((installment_amount > (0)::numeric)),
    CONSTRAINT check_installment_count CHECK ((installment_count > 1)),
    CONSTRAINT check_total_amount CHECK ((total_amount > (0)::numeric)),
    CONSTRAINT payment_schedules_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'suspended'::character varying, 'past_due'::character varying])::text[])))
);


ALTER TABLE registry.payment_schedules OWNER TO postgres;

--
-- Name: TABLE payment_schedules; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON TABLE registry.payment_schedules IS 'Payment schedules managed via Stripe subscriptions';


--
-- Name: COLUMN payment_schedules.stripe_subscription_id; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON COLUMN registry.payment_schedules.stripe_subscription_id IS 'Stripe subscription ID - required for all schedules';


--
-- Name: payments; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    status character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    stripe_payment_intent_id character varying(255),
    stripe_payment_method_id character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp with time zone,
    error_message text
);


ALTER TABLE registry.payments OWNER TO postgres;

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
    amount numeric(10,2) NOT NULL,
    currency text DEFAULT 'USD'::text,
    installments_allowed boolean DEFAULT false,
    installment_count integer,
    requirements jsonb DEFAULT '{}'::jsonb,
    pricing_configuration jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
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
-- Name: pricing_relationship_events; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.pricing_relationship_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    relationship_id uuid NOT NULL,
    event_type text NOT NULL,
    actor_user_id uuid NOT NULL,
    event_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    sequence_number bigint NOT NULL,
    aggregate_version integer DEFAULT 1 NOT NULL,
    CONSTRAINT valid_event_type CHECK ((event_type = ANY (ARRAY['created'::text, 'activated'::text, 'suspended'::text, 'terminated'::text, 'plan_changed'::text, 'billing_updated'::text, 'metadata_updated'::text])))
);


ALTER TABLE registry.pricing_relationship_events OWNER TO postgres;

--
-- Name: pricing_relationships; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.pricing_relationships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider_id uuid NOT NULL,
    consumer_id uuid NOT NULL,
    pricing_plan_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pricing_relationships_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'active'::text, 'suspended'::text, 'cancelled'::text])))
);


ALTER TABLE registry.pricing_relationships OWNER TO postgres;

--
-- Name: pricing_relationship_current_state; Type: VIEW; Schema: registry; Owner: postgres
--

CREATE VIEW registry.pricing_relationship_current_state AS
 WITH latest_events AS (
         SELECT DISTINCT ON (pricing_relationship_events.relationship_id) pricing_relationship_events.relationship_id,
            pricing_relationship_events.event_type,
            pricing_relationship_events.event_data,
            pricing_relationship_events.occurred_at,
            pricing_relationship_events.actor_user_id
           FROM registry.pricing_relationship_events
          ORDER BY pricing_relationship_events.relationship_id, pricing_relationship_events.sequence_number DESC
        )
 SELECT pr.id,
    pr.provider_id,
    pr.consumer_id,
    pr.pricing_plan_id,
    pr.status,
    pr.metadata,
    le.event_type AS last_event_type,
    le.occurred_at AS last_event_at,
    le.actor_user_id AS last_actor_id,
    pr.created_at,
    pr.updated_at
   FROM (registry.pricing_relationships pr
     LEFT JOIN latest_events le ON ((le.relationship_id = pr.id)));


ALTER VIEW registry.pricing_relationship_current_state OWNER TO postgres;

--
-- Name: pricing_relationship_events_sequence_number_seq; Type: SEQUENCE; Schema: registry; Owner: postgres
--

CREATE SEQUENCE registry.pricing_relationship_events_sequence_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE registry.pricing_relationship_events_sequence_number_seq OWNER TO postgres;

--
-- Name: pricing_relationship_events_sequence_number_seq; Type: SEQUENCE OWNED BY; Schema: registry; Owner: postgres
--

ALTER SEQUENCE registry.pricing_relationship_events_sequence_number_seq OWNED BY registry.pricing_relationship_events.sequence_number;


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
    program_type_slug text
);


ALTER TABLE registry.projects OWNER TO postgres;

--
-- Name: scheduled_payments; Type: TABLE; Schema: registry; Owner: postgres
--

CREATE TABLE registry.scheduled_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_schedule_id uuid NOT NULL,
    payment_id uuid,
    installment_number integer NOT NULL,
    amount numeric(10,2) NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying,
    paid_at timestamp with time zone,
    failed_at timestamp with time zone,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT check_installment_number CHECK ((installment_number > 0)),
    CONSTRAINT check_scheduled_amount CHECK ((amount > (0)::numeric)),
    CONSTRAINT scheduled_payments_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'completed'::character varying, 'failed'::character varying, 'cancelled'::character varying])::text[])))
);


ALTER TABLE registry.scheduled_payments OWNER TO postgres;

--
-- Name: TABLE scheduled_payments; Type: COMMENT; Schema: registry; Owner: postgres
--

COMMENT ON TABLE registry.scheduled_payments IS 'Individual installment tracking - status updated via Stripe webhooks';


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
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
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
    magic_link_expiry_hours integer DEFAULT 24,
    CONSTRAINT tenants_billing_status_check CHECK ((billing_status = ANY (ARRAY['trial'::text, 'active'::text, 'past_due'::text, 'cancelled'::text, 'incomplete'::text])))
);


ALTER TABLE registry.tenants OWNER TO postgres;

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
    outcome_definition_id uuid
);


ALTER TABLE registry.workflow_steps OWNER TO postgres;

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
-- Name: pricing_relationship_events sequence_number; Type: DEFAULT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationship_events ALTER COLUMN sequence_number SET DEFAULT nextval('registry.pricing_relationship_events_sequence_number_seq'::regclass);


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
-- Data for Name: billing_periods; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.billing_periods (id, period_start, period_end, calculated_amount, payment_status, stripe_invoice_id, stripe_payment_intent_id, processed_at, metadata, created_at, updated_at, pricing_relationship_id) FROM stdin;
\.


--
-- Data for Name: drop_requests; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.drop_requests (id, enrollment_id, requested_by, reason, refund_requested, refund_amount_requested, status, admin_notes, processed_by, processed_at, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: enrollments; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.enrollments (id, session_id, student_id, status, metadata, created_at, updated_at, family_member_id, payment_id, parent_id, student_type, drop_reason, dropped_at, dropped_by, refund_status, refund_amount, transfer_to_session_id, transfer_status) FROM stdin;
\.


--
-- Data for Name: events; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.events (id, "time", duration, location_id, project_id, teacher_id, metadata, notes, created_at, updated_at, min_age, max_age, capacity, event_type, status) FROM stdin;
\.


--
-- Data for Name: family_members; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.family_members (id, family_id, child_name, birth_date, grade, medical_info, emergency_contact, notes, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: locations; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.locations (id, name, slug, address_info, metadata, notes, created_at, updated_at, address_street, address_city, address_state, address_zip, capacity, contact_info, facilities, latitude, longitude) FROM stdin;
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
128d5ee1-3c5a-4130-ae23-679766de97da	Program Announcement	Important Update: {{program_name}}	Dear {{parent_name}},\n\nWe have an important announcement regarding {{program_name}}.\n\n{{announcement_details}}\n\nIf you have any questions, please don't hesitate to contact us.\n\nBest regards,\n{{sender_name}}\n{{organization_name}}	announcement	program	{"parent_name": "Parent's name", "sender_name": "Staff member name", "program_name": "Name of the program", "organization_name": "Organization name", "announcement_details": "Details of the announcement"}	00000000-0000-0000-0000-000000000000	t	2026-04-07 13:43:33.394118+00	2026-04-07 13:43:33.394118+00
ff0ef62f-9bf5-4920-976f-3776e053e348	Session Update	Session Update: {{session_name}}	Dear {{parent_name}},\n\nWe wanted to update you about {{session_name}} for {{child_name}}.\n\n{{update_details}}\n\nThank you for your understanding.\n\nBest regards,\n{{sender_name}}	update	session	{"child_name": "Child's name", "parent_name": "Parent's name", "sender_name": "Staff member name", "session_name": "Name of the session", "update_details": "Details of the update"}	00000000-0000-0000-0000-000000000000	t	2026-04-07 13:43:33.394118+00	2026-04-07 13:43:33.394118+00
9cda9a66-0c38-4057-a235-752d2a02f0bb	Emergency Alert	URGENT: {{emergency_title}}	Dear {{parent_name}},\n\nThis is an urgent message regarding {{scope_description}}.\n\n{{emergency_details}}\n\nPlease take immediate action as needed.\n\n{{contact_information}}\n\n{{sender_name}}\n{{organization_name}}	emergency	tenant-wide	{"parent_name": "Parent's name", "sender_name": "Staff member name", "emergency_title": "Title of emergency", "emergency_details": "Emergency details", "organization_name": "Organization name", "scope_description": "What the emergency affects", "contact_information": "Emergency contact info"}	00000000-0000-0000-0000-000000000000	t	2026-04-07 13:43:33.394118+00	2026-04-07 13:43:33.394118+00
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

COPY registry.payment_items (id, payment_id, enrollment_id, description, amount, quantity, metadata, created_at) FROM stdin;
\.


--
-- Data for Name: payment_schedules; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.payment_schedules (id, enrollment_id, pricing_plan_id, stripe_subscription_id, total_amount, installment_amount, installment_count, status, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.payments (id, user_id, amount, currency, status, stripe_payment_intent_id, stripe_payment_method_id, metadata, created_at, updated_at, completed_at, error_message) FROM stdin;
\.


--
-- Data for Name: pricing_plans; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.pricing_plans (id, session_id, plan_scope, plan_name, plan_type, pricing_model_type, amount, currency, installments_allowed, installment_count, requirements, pricing_configuration, metadata, created_at, updated_at) FROM stdin;
aa6171f4-684f-4829-97a0-70e36431eb8c	\N	tenant	Registry Revenue Share - 2%	revenue_share	percentage	0.02	USD	f	\N	{}	{"applies_to": "customer_payments", "percentage": 0.02, "minimum_monthly": 0}	{"default": false, "description": "2% of all customer payments, no minimums"}	2026-04-07 13:43:36.718913+00	2026-04-07 13:43:36.718913+00
14414692-122b-435a-abb2-cda7f80d1288	\N	tenant	Registry Standard - $200/month	subscription	fixed	200.00	USD	f	\N	{}	{"includes": ["unlimited_programs", "unlimited_enrollments", "email_support"], "monthly_amount": 200.00}	{"default": true, "description": "Standard monthly subscription"}	2026-04-07 13:43:36.718913+00	2026-04-07 13:43:36.718913+00
1d234055-6017-4bb4-a1bb-52f1e769faf9	\N	tenant	Registry Plus - $100/month + 1%	hybrid	hybrid	100.00	USD	f	\N	{}	{"applies_to": "customer_payments", "percentage": 0.01, "monthly_base": 100.00}	{"default": false, "description": "Reduced monthly fee with revenue share"}	2026-04-07 13:43:36.718913+00	2026-04-07 13:43:36.718913+00
\.


--
-- Data for Name: pricing_relationship_events; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.pricing_relationship_events (id, relationship_id, event_type, actor_user_id, event_data, occurred_at, sequence_number, aggregate_version) FROM stdin;
\.


--
-- Data for Name: pricing_relationships; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.pricing_relationships (id, provider_id, consumer_id, pricing_plan_id, status, metadata, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: program_types; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.program_types (id, slug, name, config, created_at, updated_at) FROM stdin;
1237b8e4-59ba-4f06-b821-0c10e8917e90	afterschool	After School Program	{"standard_times": {"friday": "15:00", "monday": "15:00", "tuesday": "15:00", "thursday": "15:00", "wednesday": "14:00"}, "session_pattern": "weekly_for_x_weeks", "enrollment_rules": {"same_session_for_siblings": true}}	2026-04-07 13:43:30.992131+00	2026-04-07 13:43:30.992131
6c4c4feb-38a5-4874-81e1-b5f3f3e0a3bc	summer-camp	Summer Camp	{"standard_times": {"end": "15:00", "start": "09:00"}, "session_pattern": "daily_for_x_days", "enrollment_rules": {"same_session_for_siblings": false}}	2026-04-07 13:43:30.992131+00	2026-04-07 13:43:30.992131
\.


--
-- Data for Name: projects; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.projects (id, name, slug, metadata, notes, created_at, updated_at, program_type_slug) FROM stdin;
\.


--
-- Data for Name: scheduled_payments; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.scheduled_payments (id, payment_schedule_id, payment_id, installment_number, amount, status, paid_at, failed_at, failure_reason, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: session_events; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.session_events (id, session_id, event_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: session_teachers; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.session_teachers (id, session_id, teacher_id, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: sessions; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.sessions (id, name, slug, metadata, notes, created_at, updated_at, session_type, start_date, end_date, status, capacity) FROM stdin;
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

COPY registry.tenant_users (tenant_id, user_id, is_primary, created_at) FROM stdin;
\.


--
-- Data for Name: tenants; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.tenants (id, name, slug, created_at, stripe_customer_id, stripe_subscription_id, billing_status, trial_ends_at, subscription_started_at, canonical_domain, magic_link_expiry_hours) FROM stdin;
3f4e5c15-2923-464f-a78c-8097737a8469	Registry System	registry	2026-04-07 13:43:29.368329+00	\N	\N	trial	\N	\N	\N	24
00000000-0000-0000-0000-000000000000	Registry Platform	registry-platform	2026-04-07 13:43:36.718913+00	\N	\N	active	\N	\N	\N	24
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
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.users (id, username, passhash, created_at, birth_date, user_type, grade, email_verified_at, invite_pending) FROM stdin;
\.


--
-- Data for Name: waitlist; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.waitlist (id, session_id, location_id, student_id, parent_id, "position", status, offered_at, expires_at, notes, created_at, updated_at, family_member_id) FROM stdin;
\.


--
-- Data for Name: workflow_runs; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.workflow_runs (id, workflow_id, latest_step_id, continuation_id, user_id, data, created_at) FROM stdin;
\.


--
-- Data for Name: workflow_steps; Type: TABLE DATA; Schema: registry; Owner: postgres
--

COPY registry.workflow_steps (id, slug, description, workflow_id, template_id, metadata, depends_on, created_at, updated_at, class, outcome_definition_id) FROM stdin;
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
c9235c00bc368836d5323cd4b98cadfa673aa00e	a363697ff7f1f2ad0642dfc426f003e430fbb342	users	registry	initial creation of users table and basic schema etc	2026-04-07 13:43:29.015546+00	Chris Prather	chris.prather@tamarou.com	2024-05-13 17:21:58+00	Chris Prather	chris@prather.org
2960f6c6a1df94ef7f1c75a036db14aefe121bc5	978d2b0afaad7749217fc4bf998d858c91cb9e93	workflows	registry	add workflows\n\nWorkflows define a sequence of steps to be executed. We process each step and record the outcome in a workflow run.	2026-04-07 13:43:29.258246+00	Chris Prather	chris.prather@tamarou.com	2024-05-13 17:30:35+00	Chris Prather	chris@prather.org
2abd1a15dc06e9db731062527f8541e8c79ffb6f	24d73f7d6572fe110f256ca48b0a2a48dfafa96b	tenant-on-boarding	registry	create an onboarding workflow for tenants	2026-04-07 13:43:29.504337+00	Chris Prather	chris.prather@tamarou.com	2024-05-20 21:00:32+00	Chris Prather	chris@prather.org
2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c	707b1c42fa45736727df395e145cbf439387c241	schema-based-multitennancy	registry	add the tools to do the schema-based multi-tenancy	2026-04-07 13:43:29.733428+00	Chris Prather	chris.prather@tamarou.com	2024-05-21 01:43:52+00	Chris Prather	chris@prather.org
5920ebcdc5fd6c9478af9fb1e435aedd26b5b5ce	841ff17f8bd522a515385b293e9914d111f0fd19	events-and-sessions	registry	Add events and sessions to the system	2026-04-07 13:43:29.995435+00	Chris Prather	chris.prather@tamarou.com	2024-05-31 03:36:11+00	Chris Prather	chris.prather@tamarou.com
72bea40753b0250624322f67c9a64fe479f02df7	67a0442cd1589b353394cbd451cca098bb8e8634	edit-template-workflow	registry	default workflow for editing templates	2026-04-07 13:43:30.201357+00	Chris Prather	chris.prather@tamarou.com	2025-02-11 23:59:19+00	Chris Prather	chris.prather@tamarou.com
daf665c0e9b4b1255a0cf09bb88e322f6609b59f	db62b982c609c21307787f014f58577662cca0cd	outcomes	registry	add outcome definitions	2026-04-07 13:43:30.417976+00	Chris Prather	chris.prather@tamarou.com	2025-02-21 06:45:47+00	Chris Prather	chris.prather@tamarou.com
c0bb268a4a0c27a97351166c95d50a5f6d73d0ae	7d3e7133c01ac03e83020ba1578259ec444584cd	summer-camp-module	registry	add summer-camp-module	2026-04-07 13:43:30.67393+00	Chris Prather	chris.prather@tamarou.com	2025-02-22 04:38:37+00	Chris Prather	chris.prather@tamarou.com
6d1c676dccf7787d99a54edd3ec556193ff0562d	464a90d2ef6e7939e38fa2717439f3796e2f6936	fix-tenant-workflows	registry	Fix tenant workflows to include first_step	2026-04-07 13:43:30.895354+00	Chris Prather	chris.prather@tamarou.com	2025-03-22 18:57:13+00	Chris Prather	chris.prather@tamarou.com
4d1cce9dd15eadfe664b1a909c36f1afd6d943f2	7851550d6b87474630cd02469c9772024987ce32	program-types	registry	Add program types configuration system	2026-04-07 13:43:31.102555+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 12:00:00+00	Claude	noreply@anthropic.com
ac009951a991475b6b82050987874c5e1562b227	e79fc2deea1f57838d388bd3effc672f3d9de20b	enhanced-pricing-model	registry	Transform pricing to flexible pricing_plans with multiple tiers per session	2026-04-07 13:43:31.303459+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 12:30:00+00	Claude	noreply@anthropic.com
ca85da23e2f52eb6ef3b500530d301617d8d64d3	6e636122ad2b14731a616bee3fb8d06083559358	attendance-tracking	registry	Add attendance tracking infrastructure	2026-04-07 13:43:31.507015+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 13:00:00+00	Claude	noreply@anthropic.com
9478a08db15d08f6fae783493e14eb2348a478a4	1b0a9ae93451b1aad3fcad727c30430146b39669	waitlist-management	registry	Add waitlist functionality to enrollment system	2026-04-07 13:43:31.713146+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 13:30:00+00	Claude	noreply@anthropic.com
125881c219bfb9b9053e66b6b5fb5fdb720a1ee3	fa279aaea8c8f5c6fc0fc942ac69274ced15c1d4	add-program-type-to-projects	registry	Add program type reference to projects	2026-04-07 13:43:31.899421+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 14:00:00+00	Claude	noreply@anthropic.com
b935f44f3eace95edc2fa318ed7de32c27e8ac1a	b93b975d490c4384a02a3f8a66a48d99fd35a84b	add-user-fields-for-family	registry	Add birth_date, user_type, grade fields to users	2026-04-07 13:43:32.199681+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 14:25:00+00	Claude	noreply@anthropic.com
7deaa9fb9f8f3d0309d635af087792c28525f78e	189953a84a37895f33e367d8eb0fe3b647a2bfdf	multi-child-data-model	registry	Add family_members table for multi-child support	2026-04-07 13:43:32.482999+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 14:30:00+00	Claude	noreply@anthropic.com
815c14422aeab29c0c21415ea7e8927785a1c910	36fd27b0aff2c634ec86eb7662a0ecbc11d188e6	payments	registry	Add payments infrastructure for Stripe integration	2026-04-07 13:43:32.738045+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 19:00:00+00	Claude	noreply@anthropic.com
eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6	344a280c4b37d460e57e312c538aa0507dae53e1	add-payment-to-enrollments	registry	Add payment_id reference to enrollments table	2026-04-07 13:43:32.975042+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 19:15:00+00	Claude	noreply@anthropic.com
acd808bf85b5a9d8971f598186ced619196ffd0e	8cdbcbf5f5d6b5933c1027b75293e23c21f82f45	notifications-and-preferences	registry	Add notifications and user preferences for attendance tracking	2026-04-07 13:43:33.272134+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 10:00:00+00	Claude	noreply@anthropic.com
5ce709b8eff5b3b920e7a675d78bee9dabd98367	9f6bfbd59ca138c524285ed7d9f0b7895354f801	parent-communication-system	registry	Add parent communication system with messages, recipients, and templates	2026-04-07 13:43:33.573199+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 11:00:00+00	Claude	noreply@anthropic.com
fbe73787977942423bb4d7ba5dd152c0c1551e38	fea7e5a85e605358de32808abb27b09f7dd78e83	performance-optimization	registry	Add database indexes and performance optimizations for production readiness	2026-04-07 13:43:33.88132+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 15:00:00+00	Claude	noreply@anthropic.com
d7d8aaecb2610865fd3801bb68ef57e474b29181	4a0067318476e1aa7150a0f54458884434cf9bfb	stripe-subscription-integration	registry	Add Stripe subscription integration for tenant billing	2026-04-07 13:43:34.089572+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 16:00:00+00	Claude	noreply@anthropic.com
8eb88eeec3cb411430882061df8d5563af64ba1c	3fa34c99f03fa41b55239b2a0c7f393ba3d49bbf	fix-multi-child-enrollments	registry	Fix multi-child enrollment constraints for cleaner architecture	2026-04-07 13:43:34.292775+00	Chris Prather	chris.prather@tamarou.com	2025-07-15 00:34:24+00	Chris Prather	chris.prather@tamarou.com
4883848eccc158220c9e751882d20ae963d71f52	c4e3ea6ffbffc982060b0d165f60f0ff17bf78e7	flexible-enrollment-architecture	registry	Create flexible enrollment architecture supporting family, individual, group, and corporate students	2026-04-07 13:43:34.502307+00	Chris Prather	chris.prather@tamarou.com	2025-07-15 01:09:59+00	Chris Prather	chris.prather@tamarou.com
f6dbddd094284b0b7296c6e8258922882ae24b5d	b5baa9d2cf71178ed6fd3382231eb69d0b310cfd	remove-student-id-foreign-key	registry	Remove student_id foreign key constraint to support polymorphic student references	2026-04-07 13:43:34.690891+00	Chris Prather	chris.prather@tamarou.com	2025-07-15 01:28:59+00	Chris Prather	chris.prather@tamarou.com
ffe9a13ee38d1ffa2c706750718b34126adfe6e1	d2feca17971e5f93417b098a4295ff70ead570ee	fix-waitlist-family-member-refs	registry	Fix waitlist student_id to reference family_members instead of users	2026-04-07 13:43:34.877921+00	Chris Prather	chris.prather@tamarou.com	2025-07-16 14:30:00+00	Claude	noreply@anthropic.com
3c3d83d65febc9de2fbce70f02fa01b5483736e8	49be975f75b20172863921261abf3906bc100990	fix-waitlist-reorder	registry	Fix waitlist position reordering to avoid unique constraint violations	2026-04-07 13:43:35.101053+00	Chris Prather	chris.prather@tamarou.com	2025-07-16 12:30:00+00	Claude	noreply@anthropic.com
300e4d9f1d6bafe1b45f937ea482260f3313760d	b2b54846389dbdf3e2cf7ecbb15ae53fb4175d82	fix-waitlist-reorder-v2	registry	Improved waitlist position reordering to fully avoid constraint violations	2026-04-07 13:43:35.342269+00	Chris Prather	chris.prather@tamarou.com	2025-07-16 22:50:00+00	Claude	noreply@anthropic.com
0903ffab54af2242711b1cb470a44753acf6c9d7	695f0a352ff02e4b5f84381856fe538ac1badbb7	fix-waitlist-reorder-v3	registry	Remove problematic database trigger and handle position reordering in application code	2026-04-07 13:43:35.580145+00	Chris Prather	chris.prather@tamarou.com	2025-07-17 00:00:00+00	Claude	noreply@anthropic.com
acbd53f8d5ddfc205c3c1ca518ed92170803e32c	7b6df5319ffd75e81b5f3f06e95102a1df7f2e92	drop-transfer-business-rules	registry	Add drop and transfer business rules with admin approval workflow	2026-04-07 13:43:35.851639+00	Chris Prather	chris.prather@tamarou.com	2025-09-18 00:00:00+00	Claude	noreply@anthropic.com
41ae5ed8ebd0150b8a8c2987bdbfd98967252b18	4ca09b1d82b01de2a829979849fa4a7f4c3120d4	remove-waitlist-position-constraint	registry	Remove unique constraint on waitlist position to allow status-based visibility	2026-04-07 13:43:36.081826+00	Chris Prather	chris.prather@tamarou.com	2025-09-21 00:00:00+00	Claude	noreply@anthropic.com
788f8edbabafb05aef3b90f4b634beb1aaab7b8b	7dda1d870afb87ee03300b43bacf070e53c5c5ba	installment-payment-schedules	registry	Add payment schedules and scheduled payments for installment processing	2026-04-07 13:43:36.358457+00	Chris Prather	chris.prather@tamarou.com	2025-09-23 03:35:05+00	Chris Prather	chris.prather@tamarou.com
2fc34cc17316d64ee48ef1c04e4d9c5e096b29ba	e7ea8e7d72a0222c7493190abb060dd0767adb28	simplify-installment-schema-for-stripe	registry	Simplify database schema to use Stripe native scheduling and retry features	2026-04-07 13:43:36.611726+00	Chris Prather	chris.prather@tamarou.com	2025-09-24 18:00:00+00	Claude	noreply@anthropic.com
f61a99336db06d9d07bd30abcf6e18e98d7609ac	0f1e40107de5540b06f5181f72d75c6741728143	unified-pricing-infrastructure	registry	Add unified tenant-to-tenant pricing infrastructure	2026-04-07 13:43:36.903058+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 00:44:03+00	Chris Prather	chris.prather@tamarou.com
eb5973974d4f4c06b6e5a93c84b5a66bfcd8f342	031717d9b7ea0651ef6b5f67942c8c978f502dbe	consolidate-pricing-relationships	registry	Consolidate pricing relationships into unified model	2026-04-07 13:43:37.14527+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 16:07:15+00	Chris Prather	chris.prather@tamarou.com
20f187ed4e2e4c35404fcb5f7d48df933cebfcd5	6017815b229c39d2e9f7af54f1a963e3257a5bf2	pricing-relationship-events	registry	Add event sourcing for pricing relationship audit trail	2026-04-07 13:43:37.358617+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 19:55:59+00	Chris Prather	chris.prather@tamarou.com
5f3d84a4d2158ce0ffcfeabc5772970faca7c3d3	f41063facc70f0ff67e7cc54de594af5b99d358b	remove-pricing-plan-relationship-fields	registry	Remove obsolete target_tenant_id and offering_tenant_id from pricing_plans	2026-04-07 13:43:37.556602+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 22:27:51+00	Chris Prather	chris.prather@tamarou.com
a2248de7c1f81778ea19e6f9bc5c94e806e21268	5c6daf2fa1ab2205c6f0f0a0b153947e9304f3bd	passwordless-auth	registry	Passwordless auth: passkeys, magic links, API keys	2026-04-07 13:43:37.77058+00	Chris Prather	chris.prather@tamarou.com	2026-03-25 00:00:00+00	Chris Prather	chris.prather@tamarou.com
afdf73989587e92e423e0b5f643361890a90a860	bdd207b58bea14042c69ffad9efcc71e3cbfbcd7	auth-notification-types	registry	Add auth notification types to notification_type enum	2026-04-07 13:43:37.957629+00	Chris Prather	chris.prather@tamarou.com	2026-03-30 06:56:54+00	Chris Prather	chris.prather@tamarou.com
c0834addb5a970c41dc185be91f226cba562e013	314f27eca2ee77ce95e888776a12618b7d1bb0fc	tenant-domains	registry	Custom domain management for tenants	2026-04-07 13:43:38.200412+00	Chris Prather	chris.prather@tamarou.com	2026-03-30 19:04:42+00	Chris Prather	chris.prather@tamarou.com
5656344b5447eb9e8d5b274f18d9fbfffa20f8d4	aeab9e685093de23275127520d1387c90bff2e78	magic-link-verification	registry	Add verified_at column for two-step magic link flow	2026-04-07 13:43:38.434434+00	Chris Prather	chris.prather@tamarou.com	2026-03-31 12:11:05+00	Chris Prather	chris.prather@tamarou.com
c3c7ae6599f4db30315a79d7021519f29dafa31d	ca3c13270b018c747b12a06b702742a416a46a0e	waitlist-accepted-status	registry	Add accepted status to waitlist check constraint	2026-04-07 13:43:38.658344+00	Chris Prather	chris.prather@tamarou.com	2026-04-05 01:37:21+00	Chris Prather	chris.prather@tamarou.com
c5594296b541b820c84351dedb44652f4d0cd299	c2a394082896f47268c9904b6a63dab8228acf29	seed-registry-storefront	registry	Seed registry tenant storefront with platform offering	2026-04-07 13:43:38.877432+00	Chris Prather	chris.prather@tamarou.com	2026-04-07 13:42:30+00	Chris Prather	chris.prather@tamarou.com
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
c5594296b541b820c84351dedb44652f4d0cd299	require	events-and-sessions	5920ebcdc5fd6c9478af9fb1e435aedd26b5b5ce
\.


--
-- Data for Name: events; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.events (event, change_id, change, project, note, requires, conflicts, tags, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
deploy	c9235c00bc368836d5323cd4b98cadfa673aa00e	users	registry	initial creation of users table and basic schema etc	{}	{}	{}	2026-04-07 13:43:29.018902+00	Chris Prather	chris.prather@tamarou.com	2024-05-13 17:21:58+00	Chris Prather	chris@prather.org
deploy	2960f6c6a1df94ef7f1c75a036db14aefe121bc5	workflows	registry	add workflows\n\nWorkflows define a sequence of steps to be executed. We process each step and record the outcome in a workflow run.	{users}	{}	{}	2026-04-07 13:43:29.262821+00	Chris Prather	chris.prather@tamarou.com	2024-05-13 17:30:35+00	Chris Prather	chris@prather.org
deploy	2abd1a15dc06e9db731062527f8541e8c79ffb6f	tenant-on-boarding	registry	create an onboarding workflow for tenants	{workflows,users}	{}	{}	2026-04-07 13:43:29.508837+00	Chris Prather	chris.prather@tamarou.com	2024-05-20 21:00:32+00	Chris Prather	chris@prather.org
deploy	2f7ae3c1f6f41d31425a9ba8fa21f2e73560115c	schema-based-multitennancy	registry	add the tools to do the schema-based multi-tenancy	{tenant-on-boarding}	{}	{}	2026-04-07 13:43:29.736464+00	Chris Prather	chris.prather@tamarou.com	2024-05-21 01:43:52+00	Chris Prather	chris@prather.org
deploy	5920ebcdc5fd6c9478af9fb1e435aedd26b5b5ce	events-and-sessions	registry	Add events and sessions to the system	{schema-based-multitennancy}	{}	{}	2026-04-07 13:43:29.998319+00	Chris Prather	chris.prather@tamarou.com	2024-05-31 03:36:11+00	Chris Prather	chris.prather@tamarou.com
deploy	72bea40753b0250624322f67c9a64fe479f02df7	edit-template-workflow	registry	default workflow for editing templates	{}	{}	{}	2026-04-07 13:43:30.203369+00	Chris Prather	chris.prather@tamarou.com	2025-02-11 23:59:19+00	Chris Prather	chris.prather@tamarou.com
deploy	daf665c0e9b4b1255a0cf09bb88e322f6609b59f	outcomes	registry	add outcome definitions	{}	{}	{}	2026-04-07 13:43:30.419764+00	Chris Prather	chris.prather@tamarou.com	2025-02-21 06:45:47+00	Chris Prather	chris.prather@tamarou.com
deploy	c0bb268a4a0c27a97351166c95d50a5f6d73d0ae	summer-camp-module	registry	add summer-camp-module	{}	{}	{}	2026-04-07 13:43:30.676009+00	Chris Prather	chris.prather@tamarou.com	2025-02-22 04:38:37+00	Chris Prather	chris.prather@tamarou.com
deploy	6d1c676dccf7787d99a54edd3ec556193ff0562d	fix-tenant-workflows	registry	Fix tenant workflows to include first_step	{schema-based-multitennancy}	{}	{}	2026-04-07 13:43:30.898424+00	Chris Prather	chris.prather@tamarou.com	2025-03-22 18:57:13+00	Chris Prather	chris.prather@tamarou.com
deploy	4d1cce9dd15eadfe664b1a909c36f1afd6d943f2	program-types	registry	Add program types configuration system	{schema-based-multitennancy}	{}	{}	2026-04-07 13:43:31.104483+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 12:00:00+00	Claude	noreply@anthropic.com
deploy	ac009951a991475b6b82050987874c5e1562b227	enhanced-pricing-model	registry	Transform pricing to flexible pricing_plans with multiple tiers per session	{summer-camp-module}	{}	{}	2026-04-07 13:43:31.305581+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 12:30:00+00	Claude	noreply@anthropic.com
deploy	ca85da23e2f52eb6ef3b500530d301617d8d64d3	attendance-tracking	registry	Add attendance tracking infrastructure	{summer-camp-module,program-types}	{}	{}	2026-04-07 13:43:31.509267+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 13:00:00+00	Claude	noreply@anthropic.com
deploy	9478a08db15d08f6fae783493e14eb2348a478a4	waitlist-management	registry	Add waitlist functionality to enrollment system	{summer-camp-module,program-types}	{}	{}	2026-04-07 13:43:31.715479+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 13:30:00+00	Claude	noreply@anthropic.com
deploy	125881c219bfb9b9053e66b6b5fb5fdb720a1ee3	add-program-type-to-projects	registry	Add program type reference to projects	{program-types}	{}	{}	2026-04-07 13:43:31.901437+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 14:00:00+00	Claude	noreply@anthropic.com
deploy	b935f44f3eace95edc2fa318ed7de32c27e8ac1a	add-user-fields-for-family	registry	Add birth_date, user_type, grade fields to users	{users}	{}	{}	2026-04-07 13:43:32.203188+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 14:25:00+00	Claude	noreply@anthropic.com
deploy	7deaa9fb9f8f3d0309d635af087792c28525f78e	multi-child-data-model	registry	Add family_members table for multi-child support	{summer-camp-module,add-user-fields-for-family,program-types}	{}	{}	2026-04-07 13:43:32.486991+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 14:30:00+00	Claude	noreply@anthropic.com
deploy	815c14422aeab29c0c21415ea7e8927785a1c910	payments	registry	Add payments infrastructure for Stripe integration	{schema-based-multitennancy}	{}	{}	2026-04-07 13:43:32.741772+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 19:00:00+00	Claude	noreply@anthropic.com
deploy	eee70c0e408183c5d818fa1a6ce7e3b34d3b7cf6	add-payment-to-enrollments	registry	Add payment_id reference to enrollments table	{payments,summer-camp-module}	{}	{}	2026-04-07 13:43:32.97921+00	Chris Prather	chris.prather@tamarou.com	2025-01-27 19:15:00+00	Claude	noreply@anthropic.com
deploy	acd808bf85b5a9d8971f598186ced619196ffd0e	notifications-and-preferences	registry	Add notifications and user preferences for attendance tracking	{attendance-tracking}	{}	{}	2026-04-07 13:43:33.276088+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 10:00:00+00	Claude	noreply@anthropic.com
deploy	5ce709b8eff5b3b920e7a675d78bee9dabd98367	parent-communication-system	registry	Add parent communication system with messages, recipients, and templates	{notifications-and-preferences}	{}	{}	2026-04-07 13:43:33.576636+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 11:00:00+00	Claude	noreply@anthropic.com
deploy	fbe73787977942423bb4d7ba5dd152c0c1551e38	performance-optimization	registry	Add database indexes and performance optimizations for production readiness	{parent-communication-system}	{}	{}	2026-04-07 13:43:33.884485+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 15:00:00+00	Claude	noreply@anthropic.com
deploy	d7d8aaecb2610865fd3801bb68ef57e474b29181	stripe-subscription-integration	registry	Add Stripe subscription integration for tenant billing	{enhanced-pricing-model}	{}	{}	2026-04-07 13:43:34.091694+00	Chris Prather	chris.prather@tamarou.com	2025-01-28 16:00:00+00	Claude	noreply@anthropic.com
deploy	8eb88eeec3cb411430882061df8d5563af64ba1c	fix-multi-child-enrollments	registry	Fix multi-child enrollment constraints for cleaner architecture	{multi-child-data-model}	{}	{}	2026-04-07 13:43:34.294983+00	Chris Prather	chris.prather@tamarou.com	2025-07-15 00:34:24+00	Chris Prather	chris.prather@tamarou.com
deploy	4883848eccc158220c9e751882d20ae963d71f52	flexible-enrollment-architecture	registry	Create flexible enrollment architecture supporting family, individual, group, and corporate students	{fix-multi-child-enrollments}	{}	{}	2026-04-07 13:43:34.504509+00	Chris Prather	chris.prather@tamarou.com	2025-07-15 01:09:59+00	Chris Prather	chris.prather@tamarou.com
deploy	f6dbddd094284b0b7296c6e8258922882ae24b5d	remove-student-id-foreign-key	registry	Remove student_id foreign key constraint to support polymorphic student references	{flexible-enrollment-architecture}	{}	{}	2026-04-07 13:43:34.693134+00	Chris Prather	chris.prather@tamarou.com	2025-07-15 01:28:59+00	Chris Prather	chris.prather@tamarou.com
deploy	ffe9a13ee38d1ffa2c706750718b34126adfe6e1	fix-waitlist-family-member-refs	registry	Fix waitlist student_id to reference family_members instead of users	{remove-student-id-foreign-key}	{}	{}	2026-04-07 13:43:34.88016+00	Chris Prather	chris.prather@tamarou.com	2025-07-16 14:30:00+00	Claude	noreply@anthropic.com
deploy	3c3d83d65febc9de2fbce70f02fa01b5483736e8	fix-waitlist-reorder	registry	Fix waitlist position reordering to avoid unique constraint violations	{waitlist-management}	{}	{}	2026-04-07 13:43:35.104316+00	Chris Prather	chris.prather@tamarou.com	2025-07-16 12:30:00+00	Claude	noreply@anthropic.com
deploy	300e4d9f1d6bafe1b45f937ea482260f3313760d	fix-waitlist-reorder-v2	registry	Improved waitlist position reordering to fully avoid constraint violations	{fix-waitlist-reorder}	{}	{}	2026-04-07 13:43:35.346216+00	Chris Prather	chris.prather@tamarou.com	2025-07-16 22:50:00+00	Claude	noreply@anthropic.com
deploy	0903ffab54af2242711b1cb470a44753acf6c9d7	fix-waitlist-reorder-v3	registry	Remove problematic database trigger and handle position reordering in application code	{fix-waitlist-reorder-v2}	{}	{}	2026-04-07 13:43:35.583357+00	Chris Prather	chris.prather@tamarou.com	2025-07-17 00:00:00+00	Claude	noreply@anthropic.com
deploy	acbd53f8d5ddfc205c3c1ca518ed92170803e32c	drop-transfer-business-rules	registry	Add drop and transfer business rules with admin approval workflow	{fix-multi-child-enrollments}	{}	{}	2026-04-07 13:43:35.854754+00	Chris Prather	chris.prather@tamarou.com	2025-09-18 00:00:00+00	Claude	noreply@anthropic.com
deploy	41ae5ed8ebd0150b8a8c2987bdbfd98967252b18	remove-waitlist-position-constraint	registry	Remove unique constraint on waitlist position to allow status-based visibility	{fix-waitlist-reorder-v3}	{}	{}	2026-04-07 13:43:36.084847+00	Chris Prather	chris.prather@tamarou.com	2025-09-21 00:00:00+00	Claude	noreply@anthropic.com
deploy	788f8edbabafb05aef3b90f4b634beb1aaab7b8b	installment-payment-schedules	registry	Add payment schedules and scheduled payments for installment processing	{payments}	{}	{}	2026-04-07 13:43:36.361639+00	Chris Prather	chris.prather@tamarou.com	2025-09-23 03:35:05+00	Chris Prather	chris.prather@tamarou.com
deploy	2fc34cc17316d64ee48ef1c04e4d9c5e096b29ba	simplify-installment-schema-for-stripe	registry	Simplify database schema to use Stripe native scheduling and retry features	{installment-payment-schedules}	{}	{}	2026-04-07 13:43:36.614953+00	Chris Prather	chris.prather@tamarou.com	2025-09-24 18:00:00+00	Claude	noreply@anthropic.com
deploy	f61a99336db06d9d07bd30abcf6e18e98d7609ac	unified-pricing-infrastructure	registry	Add unified tenant-to-tenant pricing infrastructure	{}	{}	{}	2026-04-07 13:43:36.905311+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 00:44:03+00	Chris Prather	chris.prather@tamarou.com
deploy	eb5973974d4f4c06b6e5a93c84b5a66bfcd8f342	consolidate-pricing-relationships	registry	Consolidate pricing relationships into unified model	{unified-pricing-infrastructure}	{}	{}	2026-04-07 13:43:37.147456+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 16:07:15+00	Chris Prather	chris.prather@tamarou.com
deploy	20f187ed4e2e4c35404fcb5f7d48df933cebfcd5	pricing-relationship-events	registry	Add event sourcing for pricing relationship audit trail	{consolidate-pricing-relationships}	{}	{}	2026-04-07 13:43:37.360715+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 19:55:59+00	Chris Prather	chris.prather@tamarou.com
deploy	5f3d84a4d2158ce0ffcfeabc5772970faca7c3d3	remove-pricing-plan-relationship-fields	registry	Remove obsolete target_tenant_id and offering_tenant_id from pricing_plans	{}	{}	{}	2026-04-07 13:43:37.558055+00	Chris Prather	chris.prather@tamarou.com	2025-09-29 22:27:51+00	Chris Prather	chris.prather@tamarou.com
deploy	a2248de7c1f81778ea19e6f9bc5c94e806e21268	passwordless-auth	registry	Passwordless auth: passkeys, magic links, API keys	{users,schema-based-multitennancy}	{}	{}	2026-04-07 13:43:37.772875+00	Chris Prather	chris.prather@tamarou.com	2026-03-25 00:00:00+00	Chris Prather	chris.prather@tamarou.com
deploy	afdf73989587e92e423e0b5f643361890a90a860	auth-notification-types	registry	Add auth notification types to notification_type enum	{notifications-and-preferences,passwordless-auth}	{}	{}	2026-04-07 13:43:37.961685+00	Chris Prather	chris.prather@tamarou.com	2026-03-30 06:56:54+00	Chris Prather	chris.prather@tamarou.com
deploy	c0834addb5a970c41dc185be91f226cba562e013	tenant-domains	registry	Custom domain management for tenants	{notifications-and-preferences}	{}	{}	2026-04-07 13:43:38.204242+00	Chris Prather	chris.prather@tamarou.com	2026-03-30 19:04:42+00	Chris Prather	chris.prather@tamarou.com
deploy	5656344b5447eb9e8d5b274f18d9fbfffa20f8d4	magic-link-verification	registry	Add verified_at column for two-step magic link flow	{passwordless-auth}	{}	{}	2026-04-07 13:43:38.437852+00	Chris Prather	chris.prather@tamarou.com	2026-03-31 12:11:05+00	Chris Prather	chris.prather@tamarou.com
deploy	c3c7ae6599f4db30315a79d7021519f29dafa31d	waitlist-accepted-status	registry	Add accepted status to waitlist check constraint	{waitlist-management}	{}	{}	2026-04-07 13:43:38.661702+00	Chris Prather	chris.prather@tamarou.com	2026-04-05 01:37:21+00	Chris Prather	chris.prather@tamarou.com
deploy	c5594296b541b820c84351dedb44652f4d0cd299	seed-registry-storefront	registry	Seed registry tenant storefront with platform offering	{events-and-sessions}	{}	{}	2026-04-07 13:43:38.880763+00	Chris Prather	chris.prather@tamarou.com	2026-04-07 13:42:30+00	Chris Prather	chris.prather@tamarou.com
\.


--
-- Data for Name: projects; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.projects (project, uri, created_at, creator_name, creator_email) FROM stdin;
registry	\N	2026-04-07 13:43:28.809399+00	Chris Prather	chris.prather@tamarou.com
\.


--
-- Data for Name: releases; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.releases (version, installed_at, installer_name, installer_email) FROM stdin;
1.1	2026-04-07 13:43:28.806903+00	Chris Prather	chris.prather@tamarou.com
\.


--
-- Data for Name: tags; Type: TABLE DATA; Schema: sqitch; Owner: postgres
--

COPY sqitch.tags (tag_id, tag, project, change_id, note, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
\.


--
-- Name: pricing_relationship_events_sequence_number_seq; Type: SEQUENCE SET; Schema: registry; Owner: postgres
--

SELECT pg_catalog.setval('registry.pricing_relationship_events_sequence_number_seq', 1, false);


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
-- Name: billing_periods billing_periods_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.billing_periods
    ADD CONSTRAINT billing_periods_pkey PRIMARY KEY (id);


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
-- Name: enrollments enrollments_session_student_type_unique; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.enrollments
    ADD CONSTRAINT enrollments_session_student_type_unique UNIQUE (session_id, student_id, student_type);


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
-- Name: payment_schedules payment_schedules_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payment_schedules
    ADD CONSTRAINT payment_schedules_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: pricing_plans pricing_plans_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_plans
    ADD CONSTRAINT pricing_plans_pkey PRIMARY KEY (id);


--
-- Name: pricing_relationship_events pricing_relationship_events_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationship_events
    ADD CONSTRAINT pricing_relationship_events_pkey PRIMARY KEY (id);


--
-- Name: pricing_relationships pricing_relationships_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationships
    ADD CONSTRAINT pricing_relationships_pkey PRIMARY KEY (id);


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
-- Name: scheduled_payments scheduled_payments_pkey; Type: CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.scheduled_payments
    ADD CONSTRAINT scheduled_payments_pkey PRIMARY KEY (id);


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
-- Name: idx_billing_periods_period; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_billing_periods_period ON registry.billing_periods USING btree (period_start, period_end);


--
-- Name: idx_billing_periods_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_billing_periods_status ON registry.billing_periods USING btree (payment_status);


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
-- Name: idx_payment_schedules_enrollment; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payment_schedules_enrollment ON registry.payment_schedules USING btree (enrollment_id);


--
-- Name: idx_payment_schedules_pricing_plan; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payment_schedules_pricing_plan ON registry.payment_schedules USING btree (pricing_plan_id);


--
-- Name: idx_payment_schedules_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payment_schedules_status ON registry.payment_schedules USING btree (status);


--
-- Name: idx_payment_schedules_stripe_subscription; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payment_schedules_stripe_subscription ON registry.payment_schedules USING btree (stripe_subscription_id);


--
-- Name: idx_payments_amount; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_amount ON registry.payments USING btree (amount);


--
-- Name: idx_payments_created_at; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_payments_created_at ON registry.payments USING btree (created_at);


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
-- Name: idx_pricing_events_actor; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_events_actor ON registry.pricing_relationship_events USING btree (actor_user_id);


--
-- Name: idx_pricing_events_occurred; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_events_occurred ON registry.pricing_relationship_events USING btree (occurred_at DESC);


--
-- Name: idx_pricing_events_relationship; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_events_relationship ON registry.pricing_relationship_events USING btree (relationship_id);


--
-- Name: idx_pricing_events_relationship_sequence; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE UNIQUE INDEX idx_pricing_events_relationship_sequence ON registry.pricing_relationship_events USING btree (relationship_id, sequence_number);


--
-- Name: idx_pricing_events_sequence; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_events_sequence ON registry.pricing_relationship_events USING btree (relationship_id, sequence_number DESC);


--
-- Name: idx_pricing_events_type; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_events_type ON registry.pricing_relationship_events USING btree (event_type);


--
-- Name: idx_pricing_relationships_consumer; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_relationships_consumer ON registry.pricing_relationships USING btree (consumer_id);


--
-- Name: idx_pricing_relationships_plan; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_relationships_plan ON registry.pricing_relationships USING btree (pricing_plan_id);


--
-- Name: idx_pricing_relationships_provider; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_relationships_provider ON registry.pricing_relationships USING btree (provider_id);


--
-- Name: idx_pricing_relationships_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_pricing_relationships_status ON registry.pricing_relationships USING btree (status) WHERE (status = ANY (ARRAY['active'::text, 'pending'::text]));


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
-- Name: idx_scheduled_payments_payment; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_scheduled_payments_payment ON registry.scheduled_payments USING btree (payment_id);


--
-- Name: idx_scheduled_payments_schedule; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_scheduled_payments_schedule ON registry.scheduled_payments USING btree (payment_schedule_id);


--
-- Name: idx_scheduled_payments_status; Type: INDEX; Schema: registry; Owner: postgres
--

CREATE INDEX idx_scheduled_payments_status ON registry.scheduled_payments USING btree (status);


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
-- Name: pricing_relationship_events ensure_pricing_event_sequence; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER ensure_pricing_event_sequence BEFORE INSERT ON registry.pricing_relationship_events FOR EACH ROW EXECUTE FUNCTION public.ensure_event_sequence();


--
-- Name: tenant_domains tenant_domains_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER tenant_domains_updated_at BEFORE UPDATE ON registry.tenant_domains FOR EACH ROW EXECUTE FUNCTION registry.tenant_domains_updated_at();


--
-- Name: attendance_records update_attendance_records_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_attendance_records_updated_at BEFORE UPDATE ON registry.attendance_records FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: billing_periods update_billing_periods_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_billing_periods_updated_at BEFORE UPDATE ON registry.billing_periods FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


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
-- Name: payment_schedules update_payment_schedules_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_payment_schedules_updated_at BEFORE UPDATE ON registry.payment_schedules FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: payments update_payments_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_payments_updated_at BEFORE UPDATE ON registry.payments FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: pricing_relationships update_pricing_relationships_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_pricing_relationships_updated_at BEFORE UPDATE ON registry.pricing_relationships FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: program_types update_program_types_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_program_types_updated_at BEFORE UPDATE ON registry.program_types FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


--
-- Name: scheduled_payments update_scheduled_payments_updated_at; Type: TRIGGER; Schema: registry; Owner: postgres
--

CREATE TRIGGER update_scheduled_payments_updated_at BEFORE UPDATE ON registry.scheduled_payments FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();


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
-- Name: attendance_records attendance_records_student_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.attendance_records
    ADD CONSTRAINT attendance_records_student_id_fkey FOREIGN KEY (student_id) REFERENCES registry.users(id);


--
-- Name: billing_periods billing_periods_pricing_relationship_id_new_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.billing_periods
    ADD CONSTRAINT billing_periods_pricing_relationship_id_new_fkey FOREIGN KEY (pricing_relationship_id) REFERENCES registry.pricing_relationships(id);


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
-- Name: payments payments_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.payments
    ADD CONSTRAINT payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES registry.users(id);


--
-- Name: pricing_relationship_events pricing_relationship_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationship_events
    ADD CONSTRAINT pricing_relationship_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES registry.users(id);


--
-- Name: pricing_relationship_events pricing_relationship_events_relationship_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationship_events
    ADD CONSTRAINT pricing_relationship_events_relationship_id_fkey FOREIGN KEY (relationship_id) REFERENCES registry.pricing_relationships(id) ON DELETE CASCADE;


--
-- Name: pricing_relationships pricing_relationships_consumer_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationships
    ADD CONSTRAINT pricing_relationships_consumer_id_fkey FOREIGN KEY (consumer_id) REFERENCES registry.users(id);


--
-- Name: pricing_relationships pricing_relationships_pricing_plan_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationships
    ADD CONSTRAINT pricing_relationships_pricing_plan_id_fkey FOREIGN KEY (pricing_plan_id) REFERENCES registry.pricing_plans(id);


--
-- Name: pricing_relationships pricing_relationships_provider_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.pricing_relationships
    ADD CONSTRAINT pricing_relationships_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES registry.tenants(id);


--
-- Name: scheduled_payments scheduled_payments_payment_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.scheduled_payments
    ADD CONSTRAINT scheduled_payments_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES registry.payments(id);


--
-- Name: scheduled_payments scheduled_payments_payment_schedule_id_fkey; Type: FK CONSTRAINT; Schema: registry; Owner: postgres
--

ALTER TABLE ONLY registry.scheduled_payments
    ADD CONSTRAINT scheduled_payments_payment_schedule_id_fkey FOREIGN KEY (payment_schedule_id) REFERENCES registry.payment_schedules(id) ON DELETE CASCADE;


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

\unrestrict WOMXCiW80QCJ1SV6ZxzPz9eboREUCg1Yybw2PyhorzWbeSbb4SiWiId63ZuJh0Q

