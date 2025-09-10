-- Deploy registry:flexible-enrollment-architecture to pg
-- requires: fix-multi-child-enrollments

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Revert the family-specific constraint and implement a more flexible approach
ALTER TABLE enrollments DROP CONSTRAINT IF EXISTS enrollments_session_family_member_unique;

-- Make student_id required again as the primary enrollment reference
ALTER TABLE enrollments ALTER COLUMN student_id SET NOT NULL;

-- Add student_type to track what kind of student entity this is
ALTER TABLE enrollments ADD COLUMN IF NOT EXISTS student_type text DEFAULT 'family_member' 
    CHECK (student_type IN ('family_member', 'individual', 'group_member', 'corporate'));

-- Create a flexible unique constraint that allows:
-- 1. Multiple family members per parent per session (different family_member_ids)
-- 2. One individual student per session 
-- 3. Multiple group members per session
-- 4. Multiple corporate enrollees per session
-- The constraint is on (session_id, student_id, student_type) which allows
-- the same logical "student" to be enrolled in different contexts
ALTER TABLE enrollments ADD CONSTRAINT enrollments_session_student_type_unique 
    UNIQUE (session_id, student_id, student_type);

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_enrollments_student_type ON enrollments(student_type);

-- Update existing enrollments to set student_type
UPDATE enrollments 
SET student_type = CASE 
    WHEN family_member_id IS NOT NULL THEN 'family_member'
    ELSE 'individual'
END;

-- For family_member enrollments, student_id should reference the family_member, not the parent
-- This makes the model consistent: student_id always references the actual student entity
UPDATE enrollments e
SET student_id = e.family_member_id
WHERE e.family_member_id IS NOT NULL
AND e.student_type = 'family_member';

-- Propagate changes to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Drop family-specific constraint
        EXECUTE format('ALTER TABLE %I.enrollments DROP CONSTRAINT IF EXISTS enrollments_session_family_member_unique;', s);
        
        -- Make student_id required
        EXECUTE format('ALTER TABLE %I.enrollments ALTER COLUMN student_id SET NOT NULL;', s);
        
        -- Add student_type column
        EXECUTE format('ALTER TABLE %I.enrollments ADD COLUMN IF NOT EXISTS student_type text DEFAULT ''family_member'' 
            CHECK (student_type IN (''family_member'', ''individual'', ''group_member'', ''corporate''));', s);
        
        -- Add flexible constraint
        EXECUTE format('ALTER TABLE %I.enrollments ADD CONSTRAINT enrollments_session_student_type_unique 
            UNIQUE (session_id, student_id, student_type);', s);
        
        -- Create index
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_enrollments_student_type ON %I.enrollments(student_type);', s);
        
        -- Update existing enrollments
        EXECUTE format('UPDATE %I.enrollments 
            SET student_type = CASE 
                WHEN family_member_id IS NOT NULL THEN ''family_member''
                ELSE ''individual''
            END;', s);
        
        -- Update student_id for family members
        EXECUTE format('UPDATE %I.enrollments e
            SET student_id = e.family_member_id
            WHERE e.family_member_id IS NOT NULL
            AND e.student_type = ''family_member'';', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;