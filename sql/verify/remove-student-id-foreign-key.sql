-- Verify registry:remove-student-id-foreign-key on pg

BEGIN;

SET search_path TO registry, public;

-- Check that the foreign key constraint is gone
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'enrollments_student_id_fkey'
        AND table_name = 'enrollments'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'Foreign key constraint still exists';
    END IF;
END $$;

-- Test that the student_id foreign key constraint is gone by checking constraint metadata
-- We can't actually insert test data because other foreign keys still exist
SELECT 1 as verified;

ROLLBACK;