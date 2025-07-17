-- Deploy registry:remove-student-id-foreign-key to pg
-- requires: flexible-enrollment-architecture

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove the foreign key constraint from student_id to users table
-- since student_id now references different entity types based on student_type
ALTER TABLE enrollments DROP CONSTRAINT IF EXISTS enrollments_student_id_fkey;

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('ALTER TABLE %I.enrollments DROP CONSTRAINT IF EXISTS enrollments_student_id_fkey;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;