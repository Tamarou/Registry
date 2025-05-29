-- Deploy registry:tenant-on-boarding to pg
-- requires: workflows
-- requires: users

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- FIRST LET's FIX THE WORKFLOW STEPS TABLE
ALTER TABLE workflow_steps
ADD COLUMN IF NOT EXISTS
class TEXT NOT NULL DEFAULT 'Registry::DAO::WorkflowStep';

-- NEXT WE CREATE THE tenant TABLES
CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp
);

-- Add a system tenant
INSERT INTO tenants (name, slug)
VALUES (
    'Registry System',
    'registry'
) ON CONFLICT (slug) DO NOTHING;

CREATE TABLE IF NOT EXISTS tenant_profiles (
    tenant_id UUID PRIMARY KEY REFERENCES tenants (id),
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp
);

CREATE TABLE IF NOT EXISTS tenant_users (
    tenant_id UUID NOT NULL REFERENCES tenants (id),
    user_id UUID NOT NULL REFERENCES users (id),
    is_primary BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp,
    PRIMARY KEY (tenant_id, user_id)
);

COMMIT;
