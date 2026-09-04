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

-- Check that new constraint exists (may be renamed in later migrations)
DO $$
BEGIN
    -- The comment above already anticipated a rename; enrollment-reenrol-after-drop
    -- also narrows it to live rows, which a constraint cannot express, so the
    -- rule now lives as a partial unique index.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name IN ('enrollments_session_family_member_unique', 'enrollments_session_student_type_unique')
        AND table_name = 'enrollments'
        AND table_schema = 'registry'
    ) AND NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'registry' AND tablename = 'enrollments'
        AND indexname = 'enrollments_session_student_type_live'
    ) THEN
        RAISE EXCEPTION 'New constraint does not exist in any form';
    END IF;
END $$;

-- Check that parent_id column exists
SELECT parent_id FROM enrollments WHERE false;

-- Note: student_id nullability is changed back to NOT NULL in flexible-enrollment-architecture
-- This migration only needs to verify the constraint changes and parent_id column

ROLLBACK;