-- Verify registry:fix-waitlist-reorder-v2 on pg

BEGIN;

-- Check that waitlist tables exist and have the proper function
SELECT 1 FROM information_schema.tables WHERE table_name = 'waitlist' LIMIT 1;

-- Check that the reorder function exists in at least one schema
SELECT 1 FROM information_schema.routines 
WHERE routine_name = 'reorder_waitlist_positions' 
AND routine_type = 'FUNCTION'
LIMIT 1;

ROLLBACK;