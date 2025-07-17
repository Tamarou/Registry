-- Revert registry:fix-multi-child-enrollments from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove new constraint
ALTER TABLE enrollments DROP CONSTRAINT IF EXISTS enrollments_session_family_member_unique;

-- Remove parent_id column
ALTER TABLE enrollments DROP COLUMN IF EXISTS parent_id;

-- Make student_id required again
ALTER TABLE enrollments ALTER COLUMN student_id SET NOT NULL;

-- Restore old constraint
ALTER TABLE enrollments ADD CONSTRAINT enrollments_session_id_student_id_key UNIQUE (session_id, student_id);

-- Revert tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('ALTER TABLE %I.enrollments DROP CONSTRAINT IF EXISTS enrollments_session_family_member_unique;', s);
        EXECUTE format('ALTER TABLE %I.enrollments DROP COLUMN IF EXISTS parent_id;', s);
        EXECUTE format('ALTER TABLE %I.enrollments ALTER COLUMN student_id SET NOT NULL;', s);
        EXECUTE format('ALTER TABLE %I.enrollments ADD CONSTRAINT enrollments_session_id_student_id_key UNIQUE (session_id, student_id);', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;