-- Verify sacregistry:locations on pg

BEGIN;

SELECT id, name, address, notes
  FROM registry.locations
 WHERE FALSE;


ROLLBACK;
