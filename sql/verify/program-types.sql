-- Verify registry:program-types on pg

BEGIN;

SET search_path TO registry, public;

-- Verify table structure
SELECT id, slug, name, config, created_at, updated_at
FROM program_types
WHERE FALSE;

-- Verify seed data exists
SELECT 1
FROM program_types
WHERE slug IN ('afterschool', 'summer-camp')
HAVING COUNT(*) = 2;

ROLLBACK;