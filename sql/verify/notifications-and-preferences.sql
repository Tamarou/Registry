-- Verify registry:notifications-and-preferences on pg

BEGIN;

SET search_path TO registry, public;

-- Verify notification types exist
SELECT 'attendance_missing'::notification_type;
SELECT 'attendance_reminder'::notification_type;
SELECT 'general'::notification_type;

-- Verify notification channels exist
SELECT 'email'::notification_channel;
SELECT 'in_app'::notification_channel;
SELECT 'sms'::notification_channel;

-- Verify notifications table exists with correct structure
SELECT id, user_id, type, channel, subject, message, metadata, 
       sent_at, read_at, failed_at, failure_reason, created_at, updated_at
FROM notifications WHERE FALSE;

-- Verify user_preferences table exists with correct structure
SELECT id, user_id, preference_key, preference_value, created_at, updated_at
FROM user_preferences WHERE FALSE;

-- Verify indexes exist
SELECT indexname FROM pg_indexes WHERE tablename = 'notifications' AND schemaname = 'registry';
SELECT indexname FROM pg_indexes WHERE tablename = 'user_preferences' AND schemaname = 'registry';

-- Verify triggers exist
SELECT trigger_name FROM information_schema.triggers 
WHERE event_object_table = 'notifications' AND event_object_schema = 'registry';
SELECT trigger_name FROM information_schema.triggers 
WHERE event_object_table = 'user_preferences' AND event_object_schema = 'registry';

ROLLBACK;