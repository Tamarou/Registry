-- Revert registry:domain-notification-types from pg
--
-- Postgres does not support removing values from an enum type.
-- Leave the values in place on revert; rows carrying them still load.

SET client_min_messages = 'warning';
SELECT 1;
