-- Deploy registry:domain-notification-types to pg
-- requires: waitlist-joined-notification-type
--
-- domain_verified and domain_verification_failed email templates have existed
-- in full -- HTML and text bodies both -- since custom domains shipped, and
-- nothing ever created a notification of either type, nor were they values in
-- this enum. A tenant learned the outcome of verification only by revisiting
-- the page (#21).
--
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction.

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'domain_verified';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'domain_verification_failed';
