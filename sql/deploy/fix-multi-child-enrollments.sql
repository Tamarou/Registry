-- Deploy registry:fix-multi-child-enrollments to pg
-- requires: multi-child-data-model

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Drop the old constraint that prevents multiple children per parent per session
ALTER TABLE enrollments DROP CONSTRAINT IF EXISTS enrollments_session_id_student_id_key;

-- Make student_id optional since we now use family_member_id as the primary reference
ALTER TABLE enrollments ALTER COLUMN student_id DROP NOT NULL;

-- Add new constraint: one enrollment per family member per session
ALTER TABLE enrollments ADD CONSTRAINT enrollments_session_family_member_unique 
    UNIQUE (session_id, family_member_id);

-- Add parent_id to track who is responsible for payment/communication
ALTER TABLE enrollments ADD COLUMN IF NOT EXISTS parent_id uuid REFERENCES users;

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_enrollments_parent_id ON enrollments(parent_id);

-- Update existing enrollments to set parent_id from family_members
UPDATE enrollments e
SET parent_id = fm.family_id
FROM family_members fm
WHERE e.family_member_id = fm.id
AND e.parent_id IS NULL;

-- Propagate changes to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Drop old constraint
        EXECUTE format('ALTER TABLE %I.enrollments DROP CONSTRAINT IF EXISTS enrollments_session_id_student_id_key;', s);
        
        -- Make student_id optional
        EXECUTE format('ALTER TABLE %I.enrollments ALTER COLUMN student_id DROP NOT NULL;', s);
        
        -- Add new constraint
        EXECUTE format('ALTER TABLE %I.enrollments ADD CONSTRAINT enrollments_session_family_member_unique 
            UNIQUE (session_id, family_member_id);', s);
        
        -- Add parent_id column
        EXECUTE format('ALTER TABLE %I.enrollments ADD COLUMN IF NOT EXISTS parent_id uuid REFERENCES %I.users;', s, s);
        
        -- Create index
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_enrollments_parent_id ON %I.enrollments(parent_id);', s);
        
        -- Update existing enrollments
        EXECUTE format('
            UPDATE %I.enrollments e
            SET parent_id = fm.family_id
            FROM %I.family_members fm
            WHERE e.family_member_id = fm.id
            AND e.parent_id IS NULL;', s, s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;