-- Verify registry:fix-multi-child-enrollments on pg

BEGIN;

SET search_path TO registry, public;

-- Check that old constraint is gone
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'enrollments_session_id_student_id_key'
        AND table_name = 'enrollments'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'Old constraint still exists';
    END IF;
END $$;

-- Check that new constraint exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'enrollments_session_family_member_unique'
        AND table_name = 'enrollments'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'New constraint does not exist';
    END IF;
END $$;

-- Check that parent_id column exists
SELECT parent_id FROM enrollments WHERE false;

-- Check that student_id is nullable
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'enrollments'
        AND column_name = 'student_id'
        AND is_nullable = 'NO'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'student_id is still NOT NULL';
    END IF;
END $$;

ROLLBACK;