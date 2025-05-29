-- Deploy registry:multi-child-data-model to pg
-- requires: summer-camp-module

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Create family_members table in registry schema
CREATE TABLE IF NOT EXISTS family_members (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    family_id uuid NOT NULL REFERENCES users,
    child_name text NOT NULL,
    birth_date date NOT NULL,
    grade text,
    medical_info jsonb NOT NULL DEFAULT '{}',
    emergency_contact jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp
);

-- Create indexes for performance
CREATE INDEX idx_family_members_family_id ON family_members(family_id);
CREATE INDEX idx_family_members_birth_date ON family_members(birth_date);

-- Create update trigger for updated_at
CREATE TRIGGER update_family_members_updated_at BEFORE UPDATE ON family_members
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Add family_member_id to enrollments table (optional, for backward compatibility)
ALTER TABLE enrollments ADD COLUMN IF NOT EXISTS family_member_id uuid REFERENCES family_members;
CREATE INDEX idx_enrollments_family_member_id ON enrollments(family_member_id);

-- Add family_member_id to waitlist table
ALTER TABLE waitlist ADD COLUMN IF NOT EXISTS family_member_id uuid REFERENCES family_members;
CREATE INDEX idx_waitlist_family_member_id ON waitlist(family_member_id);

-- Add family_member_id to attendance_records table
ALTER TABLE attendance_records ADD COLUMN IF NOT EXISTS family_member_id uuid REFERENCES family_members;
CREATE INDEX idx_attendance_family_member_id ON attendance_records(family_member_id);

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Create family_members table
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I.family_members (
            id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
            family_id uuid NOT NULL REFERENCES %I.users,
            child_name text NOT NULL,
            birth_date date NOT NULL,
            grade text,
            medical_info jsonb NOT NULL DEFAULT ''{}'',
            emergency_contact jsonb,
            notes text,
            created_at timestamp with time zone DEFAULT now(),
            updated_at timestamp NOT NULL DEFAULT current_timestamp
        );', s, s);
        
        -- Create indexes
        EXECUTE format('CREATE INDEX idx_family_members_family_id ON %I.family_members(family_id);', s);
        EXECUTE format('CREATE INDEX idx_family_members_birth_date ON %I.family_members(birth_date);', s);
        
        -- Create trigger
        EXECUTE format('CREATE TRIGGER update_family_members_updated_at BEFORE UPDATE ON %I.family_members
            FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();', s);
        
        -- Update enrollments table
        EXECUTE format('ALTER TABLE %I.enrollments ADD COLUMN IF NOT EXISTS family_member_id uuid REFERENCES %I.family_members;', s, s);
        EXECUTE format('CREATE INDEX idx_enrollments_family_member_id ON %I.enrollments(family_member_id);', s);
        
        -- Update waitlist table
        EXECUTE format('ALTER TABLE %I.waitlist ADD COLUMN IF NOT EXISTS family_member_id uuid REFERENCES %I.family_members;', s, s);
        EXECUTE format('CREATE INDEX idx_waitlist_family_member_id ON %I.waitlist(family_member_id);', s);
        
        -- Update attendance_records table
        EXECUTE format('ALTER TABLE %I.attendance_records ADD COLUMN IF NOT EXISTS family_member_id uuid REFERENCES %I.family_members;', s, s);
        EXECUTE format('CREATE INDEX idx_attendance_family_member_id ON %I.attendance_records(family_member_id);', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Migrate existing data: Create family_members records from existing enrollments
-- This maintains backward compatibility by creating child records from student users
INSERT INTO family_members (family_id, child_name, birth_date, grade)
SELECT DISTINCT 
    COALESCE(e.student_id, w.parent_id) as family_id,
    u.username as child_name,
    COALESCE(u.birth_date, '2010-01-01'::date) as birth_date,
    u.grade
FROM users u
LEFT JOIN enrollments e ON e.student_id = u.id
LEFT JOIN waitlist w ON w.student_id = u.id
WHERE (e.id IS NOT NULL OR w.id IS NOT NULL)
AND u.user_type = 'student'
AND NOT EXISTS (
    SELECT 1 FROM family_members fm 
    WHERE fm.family_id = COALESCE(e.student_id, w.parent_id)
    AND fm.child_name = u.username
);

-- Update enrollments with family_member_id
UPDATE enrollments e
SET family_member_id = fm.id
FROM family_members fm, users u
WHERE u.id = e.student_id
AND fm.family_id = e.student_id
AND fm.child_name = u.username
AND e.family_member_id IS NULL;

-- Update waitlist with family_member_id
UPDATE waitlist w
SET family_member_id = fm.id
FROM family_members fm, users u
WHERE u.id = w.student_id
AND fm.family_id = w.parent_id
AND fm.child_name = u.username
AND w.family_member_id IS NULL;

-- Propagate data migration to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Migrate enrollment data
        EXECUTE format('
            INSERT INTO %I.family_members (family_id, child_name, birth_date, grade)
            SELECT DISTINCT 
                COALESCE(e.student_id, w.parent_id) as family_id,
                u.username as child_name,
                COALESCE(u.birth_date, ''2010-01-01''::date) as birth_date,
                u.grade
            FROM %I.users u
            LEFT JOIN %I.enrollments e ON e.student_id = u.id
            LEFT JOIN %I.waitlist w ON w.student_id = u.id
            WHERE (e.id IS NOT NULL OR w.id IS NOT NULL)
            AND u.user_type = ''student''
            AND NOT EXISTS (
                SELECT 1 FROM %I.family_members fm 
                WHERE fm.family_id = COALESCE(e.student_id, w.parent_id)
                AND fm.child_name = u.username
            );', s, s, s, s, s);
        
        -- Update enrollments
        EXECUTE format('
            UPDATE %I.enrollments e
            SET family_member_id = fm.id
            FROM %I.family_members fm
            JOIN %I.users u ON u.id = e.student_id
            WHERE fm.family_id = e.student_id
            AND fm.child_name = u.username
            AND e.family_member_id IS NULL;', s, s, s);
        
        -- Update waitlist
        EXECUTE format('
            UPDATE %I.waitlist w
            SET family_member_id = fm.id
            FROM %I.family_members fm
            JOIN %I.users u ON u.id = w.student_id
            WHERE fm.family_id = w.parent_id
            AND fm.child_name = u.username
            AND w.family_member_id IS NULL;', s, s, s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;