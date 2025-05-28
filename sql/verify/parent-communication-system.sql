-- Verify registry:parent-communication-system on pg

BEGIN;

-- Verify tables exist in registry schema
SELECT id, sender_id, subject, body, message_type, scope, scope_id, scheduled_for, sent_at, created_at, updated_at
FROM registry.messages WHERE false;

SELECT id, message_id, recipient_id, recipient_type, delivered_at, read_at, created_at
FROM registry.message_recipients WHERE false;

SELECT id, name, subject_template, body_template, message_type, scope, variables, created_by, is_active, created_at, updated_at
FROM registry.message_templates WHERE false;

-- Verify function exists (trigger functions can't be called directly)
SELECT proname FROM pg_proc WHERE proname = 'update_updated_at_column' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'registry');

-- Verify indexes exist
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_messages_sender_id' AND tablename = 'messages';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_message_recipients_message_id' AND tablename = 'message_recipients';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_message_templates_type' AND tablename = 'message_templates';

-- Verify default templates were inserted
SELECT count(*) FROM registry.message_templates WHERE is_active = true;

ROLLBACK;