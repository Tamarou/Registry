-- Revert registry:enrollment-confirmation-notification-type from pg
--
-- Postgres does not support removing values from an enum type.
-- Leave the value in place on revert; callers that inserted
-- rows with this value will still load without error.

SET client_min_messages = 'warning';
SELECT 1;
