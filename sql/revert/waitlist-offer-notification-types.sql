-- ABOUTME: Revert is a no-op: Postgres cannot remove values from an enum type.
-- ABOUTME: Rows already written with these types still load.

-- Revert registry:waitlist-offer-notification-types from pg

SET client_min_messages = 'warning';
SELECT 1;
