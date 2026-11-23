-- ABOUTME: Add waitlist_offer and waitlist_expiration to notification_type.
-- ABOUTME: The waitlist jobs create both; without them a parent who opted in was never told.

-- Deploy registry:waitlist-offer-notification-types to pg
-- requires: operator-right
--
-- ProcessWaitlist and WaitlistExpiration create notifications of these types,
-- but the enum never held them, so for a parent with the preference on the
-- insert died after the offer was made or expired and the family was not told.
--
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction.

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'waitlist_offer';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'waitlist_expiration';
