-- Deploy registry:workflows to pg
-- requires: users

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

CREATE TABLE IF NOT EXISTS workflows (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    slug text UNIQUE NOT NULL,
    name text UNIQUE NOT NULL,
    description text NULL,
    first_step text DEFAULT 'landing',
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS templates (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    html text NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS workflow_steps (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    description text NULL,
    slug text NOT NULL,
    workflow_id uuid NOT NULL REFERENCES workflows,
    template_id uuid REFERENCES templates,
    metadata jsonb NULL,
    depends_on uuid REFERENCES workflow_steps
    ON DELETE CASCADE ON UPDATE SET NULL,
    created_at timestamp with time zone DEFAULT now(),
    UNIQUE (workflow_id, slug) -- workflow steps are only unique per workflow
);

CREATE TABLE IF NOT EXISTS workflow_runs (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    workflow_id uuid NOT NULL REFERENCES workflows,
    latest_step_id uuid REFERENCES workflow_steps,
    continuation_id uuid NULL REFERENCES workflow_runs,
    user_id uuid NULL REFERENCES users,
    data jsonb NULL,
    created_at timestamp with time zone DEFAULT now()
);

COMMIT;
