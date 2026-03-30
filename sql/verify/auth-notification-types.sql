-- Verify registry:auth-notification-types on pg

BEGIN;

SET search_path TO registry, public;

SELECT 'magic_link_login'::notification_type;
SELECT 'magic_link_invite'::notification_type;
SELECT 'email_verification'::notification_type;
SELECT 'passkey_registered'::notification_type;
SELECT 'passkey_removed'::notification_type;

ROLLBACK;
