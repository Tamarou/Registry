-- Revert sacregistry:sessions from pg

BEGIN;

DROP TABLE registry.sessions;

COMMIT;
