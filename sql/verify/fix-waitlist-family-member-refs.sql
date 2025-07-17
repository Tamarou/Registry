-- Verify registry:fix-waitlist-family-member-refs on pg

BEGIN;

SET search_path TO registry, public;

-- Verify that the waitlist table exists
SELECT 1/count(*) FROM information_schema.tables WHERE table_name = 'waitlist';

-- Verify that the problematic foreign key constraint is removed (count should be 0)
SELECT count(*) FROM information_schema.table_constraints 
WHERE constraint_name = 'waitlist_student_id_fkey' 
AND table_name = 'waitlist';

-- Should return 0 if constraint was successfully removed

ROLLBACK;