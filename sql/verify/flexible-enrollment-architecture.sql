-- Verify registry:flexible-enrollment-architecture on pg

BEGIN;

SET search_path TO registry, public;

-- Check that flexible constraint exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'enrollments_session_student_type_unique'
        AND table_name = 'enrollments'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'Flexible constraint does not exist';
    END IF;
END $$;

-- Check that student_type column exists
SELECT student_type FROM enrollments WHERE false;

-- Check that student_id is required
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'enrollments'
        AND column_name = 'student_id'
        AND is_nullable = 'NO'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'student_id should be NOT NULL';
    END IF;
END $$;

-- Check that family-specific constraint is gone
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'enrollments_session_family_member_unique'
        AND table_name = 'enrollments'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'Family-specific constraint still exists';
    END IF;
END $$;

ROLLBACK;