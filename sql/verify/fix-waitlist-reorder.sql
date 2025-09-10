-- Verify fix-waitlist-reorder

BEGIN;

-- Check that the function exists
SELECT 1 FROM pg_proc WHERE proname = 'reorder_waitlist_positions';

-- Check that the trigger exists
SELECT 1 FROM pg_trigger WHERE tgname = 'reorder_waitlist_on_removal';

ROLLBACK;