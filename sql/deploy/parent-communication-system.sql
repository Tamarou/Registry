-- Deploy registry:parent-communication-system to pg

BEGIN;

-- Create messages table for one-way communication from staff to parents
CREATE TABLE registry.messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id uuid NOT NULL,
    subject text NOT NULL,
    body text NOT NULL,
    message_type text NOT NULL CHECK (message_type IN ('announcement', 'update', 'emergency')),
    scope text NOT NULL CHECK (scope IN ('program', 'session', 'child-specific', 'location', 'tenant-wide')),
    scope_id uuid, -- references the specific program, session, child, or location
    scheduled_for timestamp with time zone,
    sent_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Create message recipients table for tracking who should receive each message
CREATE TABLE registry.message_recipients (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id uuid NOT NULL REFERENCES registry.messages(id) ON DELETE CASCADE,
    recipient_id uuid NOT NULL, -- user_id of the parent
    recipient_type text NOT NULL DEFAULT 'parent' CHECK (recipient_type IN ('parent', 'teacher', 'admin')),
    delivered_at timestamp with time zone,
    read_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Create message templates table for reusable message content
CREATE TABLE registry.message_templates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    subject_template text NOT NULL,
    body_template text NOT NULL,
    message_type text NOT NULL CHECK (message_type IN ('announcement', 'update', 'emergency')),
    scope text NOT NULL CHECK (scope IN ('program', 'session', 'child-specific', 'location', 'tenant-wide')),
    variables jsonb DEFAULT '{}', -- Available template variables
    created_by uuid NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

-- Add indexes for performance
CREATE INDEX idx_messages_sender_id ON registry.messages(sender_id);
CREATE INDEX idx_messages_type ON registry.messages(message_type);
CREATE INDEX idx_messages_scope ON registry.messages(scope, scope_id);
CREATE INDEX idx_messages_scheduled ON registry.messages(scheduled_for) WHERE scheduled_for IS NOT NULL;
CREATE INDEX idx_messages_sent ON registry.messages(sent_at) WHERE sent_at IS NOT NULL;

CREATE INDEX idx_message_recipients_message_id ON registry.message_recipients(message_id);
CREATE INDEX idx_message_recipients_recipient_id ON registry.message_recipients(recipient_id);
CREATE INDEX idx_message_recipients_unread ON registry.message_recipients(recipient_id, read_at) WHERE read_at IS NULL;

CREATE INDEX idx_message_templates_type ON registry.message_templates(message_type);
CREATE INDEX idx_message_templates_scope ON registry.message_templates(scope);
CREATE INDEX idx_message_templates_active ON registry.message_templates(is_active) WHERE is_active = true;

-- Add trigger to update updated_at timestamp
CREATE OR REPLACE FUNCTION registry.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_messages_updated_at BEFORE UPDATE ON registry.messages
    FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();

CREATE TRIGGER update_message_templates_updated_at BEFORE UPDATE ON registry.message_templates
    FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column();

-- Replicate schema to all tenant schemas
DO $$
DECLARE
    tenant_slug text;
BEGIN
    FOR tenant_slug IN 
        SELECT slug FROM registry.tenants WHERE slug != 'registry'
    LOOP
        EXECUTE format('
            CREATE TABLE %I.messages (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                sender_id uuid NOT NULL,
                subject text NOT NULL,
                body text NOT NULL,
                message_type text NOT NULL CHECK (message_type IN (''announcement'', ''update'', ''emergency'')),
                scope text NOT NULL CHECK (scope IN (''program'', ''session'', ''child-specific'', ''location'', ''tenant-wide'')),
                scope_id uuid,
                scheduled_for timestamp with time zone,
                sent_at timestamp with time zone,
                created_at timestamp with time zone NOT NULL DEFAULT now(),
                updated_at timestamp with time zone NOT NULL DEFAULT now()
            )', tenant_slug);
            
        EXECUTE format('
            CREATE TABLE %I.message_recipients (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                message_id uuid NOT NULL REFERENCES %I.messages(id) ON DELETE CASCADE,
                recipient_id uuid NOT NULL,
                recipient_type text NOT NULL DEFAULT ''parent'' CHECK (recipient_type IN (''parent'', ''teacher'', ''admin'')),
                delivered_at timestamp with time zone,
                read_at timestamp with time zone,
                created_at timestamp with time zone NOT NULL DEFAULT now()
            )', tenant_slug, tenant_slug);
            
        EXECUTE format('
            CREATE TABLE %I.message_templates (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                name text NOT NULL,
                subject_template text NOT NULL,
                body_template text NOT NULL,
                message_type text NOT NULL CHECK (message_type IN (''announcement'', ''update'', ''emergency'')),
                scope text NOT NULL CHECK (scope IN (''program'', ''session'', ''child-specific'', ''location'', ''tenant-wide'')),
                variables jsonb DEFAULT ''{}''::jsonb,
                created_by uuid NOT NULL,
                is_active boolean NOT NULL DEFAULT true,
                created_at timestamp with time zone NOT NULL DEFAULT now(),
                updated_at timestamp with time zone NOT NULL DEFAULT now()
            )', tenant_slug);

        -- Add indexes for tenant schemas
        EXECUTE format('CREATE INDEX idx_%I_messages_sender_id ON %I.messages(sender_id)', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_messages_type ON %I.messages(message_type)', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_messages_scope ON %I.messages(scope, scope_id)', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_messages_scheduled ON %I.messages(scheduled_for) WHERE scheduled_for IS NOT NULL', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_messages_sent ON %I.messages(sent_at) WHERE sent_at IS NOT NULL', tenant_slug, tenant_slug);

        EXECUTE format('CREATE INDEX idx_%I_message_recipients_message_id ON %I.message_recipients(message_id)', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_message_recipients_recipient_id ON %I.message_recipients(recipient_id)', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_message_recipients_unread ON %I.message_recipients(recipient_id, read_at) WHERE read_at IS NULL', tenant_slug, tenant_slug);

        EXECUTE format('CREATE INDEX idx_%I_message_templates_type ON %I.message_templates(message_type)', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_message_templates_scope ON %I.message_templates(scope)', tenant_slug, tenant_slug);
        EXECUTE format('CREATE INDEX idx_%I_message_templates_active ON %I.message_templates(is_active) WHERE is_active = true', tenant_slug, tenant_slug);

        -- Add triggers for tenant schemas
        EXECUTE format('CREATE TRIGGER update_%I_messages_updated_at BEFORE UPDATE ON %I.messages
            FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column()', tenant_slug, tenant_slug);
            
        EXECUTE format('CREATE TRIGGER update_%I_message_templates_updated_at BEFORE UPDATE ON %I.message_templates
            FOR EACH ROW EXECUTE FUNCTION registry.update_updated_at_column()', tenant_slug, tenant_slug);
    END LOOP;
END $$;

-- Insert some default message templates
INSERT INTO registry.message_templates (name, subject_template, body_template, message_type, scope, variables, created_by) VALUES
    ('Program Announcement', 'Important Update: {{program_name}}', 
     'Dear {{parent_name}},

We have an important announcement regarding {{program_name}}.

{{announcement_details}}

If you have any questions, please don''t hesitate to contact us.

Best regards,
{{sender_name}}
{{organization_name}}', 
     'announcement', 'program', 
     '{"program_name": "Name of the program", "parent_name": "Parent''s name", "announcement_details": "Details of the announcement", "sender_name": "Staff member name", "organization_name": "Organization name"}',
     '00000000-0000-0000-0000-000000000000'),

    ('Session Update', 'Session Update: {{session_name}}', 
     'Dear {{parent_name}},

We wanted to update you about {{session_name}} for {{child_name}}.

{{update_details}}

Thank you for your understanding.

Best regards,
{{sender_name}}', 
     'update', 'session', 
     '{"session_name": "Name of the session", "parent_name": "Parent''s name", "child_name": "Child''s name", "update_details": "Details of the update", "sender_name": "Staff member name"}',
     '00000000-0000-0000-0000-000000000000'),

    ('Emergency Alert', 'URGENT: {{emergency_title}}', 
     'Dear {{parent_name}},

This is an urgent message regarding {{scope_description}}.

{{emergency_details}}

Please take immediate action as needed.

{{contact_information}}

{{sender_name}}
{{organization_name}}', 
     'emergency', 'tenant-wide', 
     '{"parent_name": "Parent''s name", "emergency_title": "Title of emergency", "scope_description": "What the emergency affects", "emergency_details": "Emergency details", "contact_information": "Emergency contact info", "sender_name": "Staff member name", "organization_name": "Organization name"}',
     '00000000-0000-0000-0000-000000000000');

COMMIT;