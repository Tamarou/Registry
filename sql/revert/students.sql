-- Revert sacregistry:students from pg

BEGIN;

DROP TABLE registry.sessions_students;
DROP TABLE registry.students;

COMMIT;
