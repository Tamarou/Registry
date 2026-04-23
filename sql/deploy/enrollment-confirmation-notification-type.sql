-- Deploy registry:enrollment-confirmation-notification-type to pg
-- requires: auth-notification-types
--
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction.

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'enrollment_confirmation';
