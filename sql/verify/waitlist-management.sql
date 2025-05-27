-- Verify registry:waitlist-management on pg

BEGIN;

SET search_path TO registry, public;

-- Verify table structure
SELECT id, session_id, location_id, student_id, parent_id, position, status, 
       offered_at, expires_at, notes, created_at, updated_at
FROM waitlist
WHERE FALSE;

-- Verify indexes exist
SELECT 1 FROM pg_indexes 
WHERE schemaname = 'registry' 
AND tablename = 'waitlist'
AND indexname IN ('idx_waitlist_session_id', 'idx_waitlist_student_id', 
                  'idx_waitlist_parent_id', 'idx_waitlist_status', 'idx_waitlist_position');

-- Verify unique constraints
SELECT 1 FROM pg_constraint
WHERE conname LIKE '%waitlist%session_id_student_id%'
OR conname LIKE '%waitlist%session_id_position%';

-- Verify functions exist
SELECT 1 FROM pg_proc WHERE proname = 'reorder_waitlist_positions';
SELECT 1 FROM pg_proc WHERE proname = 'get_next_waitlist_position';

ROLLBACK;