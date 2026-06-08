-- Verify registry:fix-attendance-student-id-fkey on pg

BEGIN;

SET search_path TO registry, public;

-- Check that the foreign key constraint is gone from registry schema
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'attendance_records_student_id_fkey'
        AND table_name = 'attendance_records'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'Foreign key constraint attendance_records_student_id_fkey still exists';
    END IF;
END $$;

SELECT 1 as verified;

ROLLBACK;
