-- Deploy registry:auth-notification-types to pg
-- requires: notifications-and-preferences
-- requires: passwordless-auth
--
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction.

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'magic_link_login';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'magic_link_invite';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'email_verification';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'passkey_registered';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'passkey_removed';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'message_announcement';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'message_update';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'message_emergency';
