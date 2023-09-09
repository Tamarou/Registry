-- Verify sacregistry:app on pg

BEGIN;

DO $$
BEGIN
   ASSERT (SELECT has_schema_privilege('registry', 'usage'));
END $$;

ROLLBACK;
