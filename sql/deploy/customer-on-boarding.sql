-- Deploy registry:customer-on-boarding to pg
-- requires: workflows

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry,public;

-- FIRST LET's FIX THE WORKFLOW STEPS TABLE
ALTER TABLE workflow_steps
ADD COLUMN IF NOT EXISTS class TEXT NOT NULL DEFAULT 'Registry::DAO::WorkflowStep';

-- NEXT WE CREATE THE customer TABLES
CREATE TABLE IF NOT EXISTS customers (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
	slug TEXT UNIQUE NOT NULL,
    name TEXT UNIQUE NOT NULL,
    primary_user_id UUID NOT NULL references users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS customer_profiles (
    customer_id UUID PRIMARY KEY references customers(id),
    data JSONB, -- we probably want to do something more strutured here but this will do for now
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS customer_users (
    customer_id UUID NOT NULL references customers(id),
    user_id UUID NOT NULL references users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (customer_id, user_id)
);

-- CREATE THE BASIC CUSTOMER SIGNUP WORKFLOW
INSERT INTO workflows (name, slug, description)
VALUES ('Customer Onboarding', 'customer-signup', 'A workflow to onboard new customers');

INSERT INTO workflow_steps (slug, workflow_id, description)
VALUES ('landing', (SELECT id FROM workflows WHERE slug = 'customer-signup'), 'New Customer landing page');

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on)
VALUES ( 'profile', (SELECT id FROM workflows WHERE slug = 'customer-signup'), 'Customer profile page', (SELECT id FROM workflow_steps WHERE slug = 'landing'));

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on)
VALUES ( 'users', (SELECT id FROM workflows WHERE slug = 'customer-signup'), 'Customer users page', (SELECT id FROM workflow_steps WHERE slug = 'profile'));

INSERT INTO workflow_steps (slug, workflow_id, description, depends_on, class)
VALUES ( 'complete', (SELECT id FROM workflows WHERE slug = 'customer-signup'), 'Customer onboarding complete', (SELECT id FROM workflow_steps WHERE slug = 'users'), 'Registry::DAO::RegisterCustomer');

COMMIT;