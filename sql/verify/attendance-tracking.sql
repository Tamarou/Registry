-- Verify registry:attendance-tracking on pg

BEGIN;

SET search_path TO registry, public;

-- Verify table structure
SELECT id, event_id, student_id, status, marked_at, marked_by, notes, created_at, updated_at
FROM attendance_records
WHERE FALSE;

-- Verify indexes exist
SELECT 1 FROM pg_indexes 
WHERE schemaname = 'registry' 
AND tablename = 'attendance_records'
AND indexname IN ('idx_attendance_event_id', 'idx_attendance_student_id', 'idx_attendance_marked_at', 'idx_attendance_status');

-- Verify unique constraint
SELECT 1 FROM pg_constraint
WHERE conname LIKE '%attendance_records%event_id_student_id%'
AND contype = 'u';

ROLLBACK;