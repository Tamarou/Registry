-- Revert registry:users from pg

BEGIN;

DROP TABLE IF EXISTS registry.user_profiles;
DROP TABLE IF EXISTS registry.users;
DROP SCHEMA IF EXISTS registry;

COMMIT;
