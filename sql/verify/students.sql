-- Verify sacregistry:students on pg

BEGIN;

SELECT id, name, metadata, notes
FROM registry.students
WHERE FALSE;

ROLLBACK;
