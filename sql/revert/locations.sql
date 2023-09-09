-- Revert sacregistry:locations from pg

BEGIN;

ALTER TABLE registry.sessions DROP COLUMN locations_id

DROP TABLE registry.locations;

COMMIT;
