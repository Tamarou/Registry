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

-- CREATE THE BASIC TENANT SIGNUP WORKFLOW
INSERT INTO workflows (slug, name, description)
VALUES (
    'tenant-signup',
    'Tenant Onboarding',
    'A workflow to onboard new tenants'
);

INSERT INTO workflow_steps (slug, workflow_id, description)
VALUES (
    'landing',
    (
        SELECT id FROM workflows
        WHERE slug = 'tenant-signup'
    ),
    'New Tenant landing page'
);

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on)
VALUES (
    'profile',
    (
        SELECT id FROM workflows
        WHERE slug = 'tenant-signup'
    ),
    'Tenant profile page',
    (
        SELECT id
        FROM workflow_steps
        WHERE
            slug = 'landing'
            AND workflow_id = (
                SELECT workflows.id FROM workflows
                WHERE workflows.slug = 'tenant-signup'
            )
    )
);

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on)
VALUES (
    'users',
    (
        SELECT id FROM workflows
        WHERE slug = 'tenant-signup'
    ),
    'Tenant users page',
    (
        SELECT id
        FROM workflow_steps
        WHERE
            slug = 'profile'
            AND workflow_id = (
                SELECT workflows.id FROM workflows
                WHERE workflows.slug = 'tenant-signup'
            )
    )
);

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on, class)
VALUES (
    'complete',
    (
        SELECT id FROM workflows
        WHERE slug = 'tenant-signup'
    ),
    'Tenant onboarding complete',
    (
        SELECT id
        FROM workflow_steps
        WHERE
            slug = 'users'
            AND workflow_id = (
                SELECT workflows.id FROM workflows
                WHERE workflows.slug = 'tenant-signup'
            )
    ),
    'Registry::DAO::RegisterTenant'
);

COMMIT;
