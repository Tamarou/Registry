-- Revert registry:flexible-enrollment-architecture from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove flexible constraint
ALTER TABLE enrollments DROP CONSTRAINT IF EXISTS enrollments_session_student_type_unique;

-- Remove student_type column
ALTER TABLE enrollments DROP COLUMN IF EXISTS student_type;

-- Restore family-specific constraint
ALTER TABLE enrollments ADD CONSTRAINT enrollments_session_family_member_unique 
    UNIQUE (session_id, family_member_id);

-- Make student_id optional again
ALTER TABLE enrollments ALTER COLUMN student_id DROP NOT NULL;

-- Revert tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('ALTER TABLE %I.enrollments DROP CONSTRAINT IF EXISTS enrollments_session_student_type_unique;', s);
        EXECUTE format('ALTER TABLE %I.enrollments DROP COLUMN IF EXISTS student_type;', s);
        EXECUTE format('ALTER TABLE %I.enrollments ADD CONSTRAINT enrollments_session_family_member_unique 
            UNIQUE (session_id, family_member_id);', s);
        EXECUTE format('ALTER TABLE %I.enrollments ALTER COLUMN student_id DROP NOT NULL;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;