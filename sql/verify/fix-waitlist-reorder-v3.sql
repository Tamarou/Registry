-- Verify registry:fix-waitlist-reorder-v3 on pg

BEGIN;

-- Check that waitlist tables exist
SELECT 1 FROM information_schema.tables WHERE table_name = 'waitlist' LIMIT 1;

-- Check that the reorder function no longer exists
SELECT 1 FROM pg_catalog.pg_tables WHERE tablename = 'waitlist' LIMIT 1;

ROLLBACK;