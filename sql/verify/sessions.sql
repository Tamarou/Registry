-- Verify sacregistry:sessions on pg

BEGIN;

SELECT id, name, time
  FROM registry.sessions
 WHERE FALSE;

ROLLBACK;
