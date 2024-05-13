-- Verify registry:users on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry,public;

SELECT id, username, passhash FROM users WHERE FALSE;
SELECT user_id, data FROM user_profiles WHERE FALSE;

ROLLBACK;
