-- Deploy registry:workflows to pg
-- requires: users

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry,public;

CREATE TABLE IF NOT EXISTS workflows (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    slug TEXT UNIQUE NOT NULL,
    name TEXT UNIQUE NOT NULL,
    description TEXT NULL,
    first_step TEXT DEFAULT 'landing' -- slug for the first step in the workflow
);

CREATE TABLE IF NOT EXISTS templates (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    slug TEXT UNIQUE NOT NULL,
    html TEXT NOT NULL,
    metadata JSONB NULL,
    notes TEXT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS workflow_steps (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    description TEXT NULL,
    slug TEXT NOT NULL,
    workflow_id uuid NOT NULL REFERENCES workflows,
    template_id uuid REFERENCES templates,
    metadata JSONB NULL,
    depends_on uuid REFERENCES workflow_steps ON DELETE CASCADE ON UPDATE SET NULL,
    UNIQUE (workflow_id, slug) -- workflow steps are only unique per workflow
);

CREATE TABLE IF NOT EXISTS workflow_runs (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    workflow_id uuid NOT NULL REFERENCES workflows,
    latest_step_id uuid REFERENCES workflow_steps,
    user_id uuid NULL REFERENCES users,
    data JSONB NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

COMMIT;
