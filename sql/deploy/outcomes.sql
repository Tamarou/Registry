-- Deploy registry:outcomes to pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

CREATE TABLE IF NOT EXISTS outcome_definitions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text NOT NULL,
    description text,
    schema jsonb NOT NULL,
    created_at timestamp NOT NULL DEFAULT current_timestamp,
    updated_at timestamp NOT NULL DEFAULT current_timestamp
);

ALTER TABLE workflow_steps
ADD COLUMN IF NOT EXISTS outcome_definition_id uuid REFERENCES outcome_definitions;

DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       EXECUTE format('CREATE TABLE IF NOT EXISTS %I.outcome_definitions AS TABLE registry.outcome_definitions;', s);
       EXECUTE format('ALTER TABLE %I.workflow_steps ADD COLUMN IF NOT EXISTS outcome_definition_id uuid REFERENCES %I.outcome_definitions', s, s);
   END LOOP;
END;
$$ LANGUAGE plpgsql;


COMMIT;
