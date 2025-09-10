-- Revert registry:remove-student-id-foreign-key from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Restore the foreign key constraint (this may fail if data doesn't match)
ALTER TABLE enrollments ADD CONSTRAINT enrollments_student_id_fkey 
    FOREIGN KEY (student_id) REFERENCES users(id);

-- Revert tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('ALTER TABLE %I.enrollments ADD CONSTRAINT enrollments_student_id_fkey 
            FOREIGN KEY (student_id) REFERENCES %I.users(id);', s, s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;