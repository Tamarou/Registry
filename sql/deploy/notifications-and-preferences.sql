-- Deploy registry:notifications-and-preferences to pg
-- requires: attendance-tracking

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Create notification types enum
CREATE TYPE notification_type AS ENUM (
    'attendance_missing',
    'attendance_reminder', 
    'general'
);

-- Create notification channels enum
CREATE TYPE notification_channel AS ENUM (
    'email',
    'in_app',
    'sms'
);

-- Create notifications table
CREATE TABLE IF NOT EXISTS notifications (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users,
    type notification_type NOT NULL,
    channel notification_channel NOT NULL,
    subject text NOT NULL,
    message text NOT NULL,
    metadata jsonb DEFAULT '{}',
    sent_at timestamp with time zone,
    read_at timestamp with time zone,
    failed_at timestamp with time zone,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT current_timestamp
);

-- Create indexes for notifications
CREATE INDEX idx_notifications_user_id ON notifications(user_id);
CREATE INDEX idx_notifications_type ON notifications(type);
CREATE INDEX idx_notifications_channel ON notifications(channel);
CREATE INDEX idx_notifications_sent_at ON notifications(sent_at);
CREATE INDEX idx_notifications_read_at ON notifications(read_at);
CREATE INDEX idx_notifications_failed_at ON notifications(failed_at);

-- Create user preferences table
CREATE TABLE IF NOT EXISTS user_preferences (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users,
    preference_key text NOT NULL,
    preference_value jsonb NOT NULL DEFAULT '{}',
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
    
    -- Prevent duplicate preferences for same user/key
    UNIQUE (user_id, preference_key)
);

-- Create indexes for user preferences
CREATE INDEX idx_user_preferences_user_id ON user_preferences(user_id);
CREATE INDEX idx_user_preferences_key ON user_preferences(preference_key);

-- Create update triggers
CREATE TRIGGER update_notifications_updated_at BEFORE UPDATE ON notifications
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_user_preferences_updated_at BEFORE UPDATE ON user_preferences
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Insert default notification preferences for existing users
INSERT INTO user_preferences (user_id, preference_key, preference_value)
SELECT 
    id, 
    'notifications',
    '{"attendance_missing": {"email": true, "in_app": true}, "attendance_reminder": {"email": true, "in_app": true}}'::jsonb
FROM users
ON CONFLICT (user_id, preference_key) DO NOTHING;

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Create notification types enum (if not exists)
        BEGIN
            EXECUTE format('CREATE TYPE %I.notification_type AS ENUM (
                ''attendance_missing'',
                ''attendance_reminder'', 
                ''general''
            );', s);
        EXCEPTION
            WHEN duplicate_object THEN NULL;
        END;
        
        -- Create notification channels enum (if not exists)
        BEGIN
            EXECUTE format('CREATE TYPE %I.notification_channel AS ENUM (
                ''email'',
                ''in_app'',
                ''sms''
            );', s);
        EXCEPTION
            WHEN duplicate_object THEN NULL;
        END;
        
        -- Create notifications table
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I.notifications (
            id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
            user_id uuid NOT NULL REFERENCES %I.users,
            type %I.notification_type NOT NULL,
            channel %I.notification_channel NOT NULL,
            subject text NOT NULL,
            message text NOT NULL,
            metadata jsonb DEFAULT ''{}''::jsonb,
            sent_at timestamp with time zone,
            read_at timestamp with time zone,
            failed_at timestamp with time zone,
            failure_reason text,
            created_at timestamp with time zone DEFAULT now(),
            updated_at timestamp with time zone NOT NULL DEFAULT current_timestamp
        );', s, s, s, s);
        
        -- Create user preferences table
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I.user_preferences (
            id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
            user_id uuid NOT NULL REFERENCES %I.users,
            preference_key text NOT NULL,
            preference_value jsonb NOT NULL DEFAULT ''{}''::jsonb,
            created_at timestamp with time zone DEFAULT now(),
            updated_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
            UNIQUE (user_id, preference_key)
        );', s, s);
        
        -- Create indexes
        EXECUTE format('CREATE INDEX idx_notifications_user_id ON %I.notifications(user_id);', s);
        EXECUTE format('CREATE INDEX idx_notifications_type ON %I.notifications(type);', s);
        EXECUTE format('CREATE INDEX idx_notifications_channel ON %I.notifications(channel);', s);
        EXECUTE format('CREATE INDEX idx_notifications_sent_at ON %I.notifications(sent_at);', s);
        EXECUTE format('CREATE INDEX idx_notifications_read_at ON %I.notifications(read_at);', s);
        EXECUTE format('CREATE INDEX idx_notifications_failed_at ON %I.notifications(failed_at);', s);
        
        EXECUTE format('CREATE INDEX idx_user_preferences_user_id ON %I.user_preferences(user_id);', s);
        EXECUTE format('CREATE INDEX idx_user_preferences_key ON %I.user_preferences(preference_key);', s);
        
        -- Create triggers
        EXECUTE format('CREATE TRIGGER update_notifications_updated_at BEFORE UPDATE ON %I.notifications
            FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();', s);
        EXECUTE format('CREATE TRIGGER update_user_preferences_updated_at BEFORE UPDATE ON %I.user_preferences
            FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();', s);
        
        -- Insert default preferences for existing users in this tenant
        EXECUTE format('INSERT INTO %I.user_preferences (user_id, preference_key, preference_value)
        SELECT 
            id, 
            ''notifications'',
            ''{"attendance_missing": {"email": true, "in_app": true}, "attendance_reminder": {"email": true, "in_app": true}}''::jsonb
        FROM %I.users
        ON CONFLICT (user_id, preference_key) DO NOTHING;', s, s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;