-- Revert registry:notifications-and-preferences from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Drop from tenant schemas first
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Drop triggers
        EXECUTE format('DROP TRIGGER IF EXISTS update_notifications_updated_at ON %I.notifications;', s);
        EXECUTE format('DROP TRIGGER IF EXISTS update_user_preferences_updated_at ON %I.user_preferences;', s);
        
        -- Drop indexes
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_notifications_user_id;', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_notifications_type;', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_notifications_channel;', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_notifications_sent_at;', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_notifications_read_at;', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_notifications_failed_at;', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_user_preferences_user_id;', s);
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_user_preferences_key;', s);
        
        -- Drop tables
        EXECUTE format('DROP TABLE IF EXISTS %I.user_preferences;', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.notifications;', s);
        
        -- Drop types
        EXECUTE format('DROP TYPE IF EXISTS %I.notification_channel;', s);
        EXECUTE format('DROP TYPE IF EXISTS %I.notification_type;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Drop triggers
DROP TRIGGER IF EXISTS update_notifications_updated_at ON notifications;
DROP TRIGGER IF EXISTS update_user_preferences_updated_at ON user_preferences;

-- Drop indexes
DROP INDEX IF EXISTS idx_notifications_user_id;
DROP INDEX IF EXISTS idx_notifications_type;
DROP INDEX IF EXISTS idx_notifications_channel;
DROP INDEX IF EXISTS idx_notifications_sent_at;
DROP INDEX IF EXISTS idx_notifications_read_at;
DROP INDEX IF EXISTS idx_notifications_failed_at;
DROP INDEX IF EXISTS idx_user_preferences_user_id;
DROP INDEX IF EXISTS idx_user_preferences_key;

-- Drop tables
DROP TABLE IF EXISTS user_preferences;
DROP TABLE IF EXISTS notifications;

-- Drop types
DROP TYPE IF EXISTS notification_channel;
DROP TYPE IF EXISTS notification_type;

COMMIT;