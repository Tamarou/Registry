-- Revert sacregistry:app from pg

BEGIN;

DROP SCHEMA registry;

COMMIT;
