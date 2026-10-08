-- Deploy registry:waitlist-joined-notification-type to pg
-- requires: payments-record-platform-fee
--
-- A parent who joins a waitlist gets nothing in writing (#421). The only
-- waitlist message that exists is waitlist_offer, sent when a seat opens;
-- joining sends nothing, so the confirmation page is the only record and it
-- closes with the tab.
--
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction.

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'waitlist_joined';
