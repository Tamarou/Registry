-- Revert registry:fix-attendance-student-id-fkey from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Restore the foreign key constraint (may fail if data contains family_member IDs)
ALTER TABLE attendance_records ADD CONSTRAINT attendance_records_student_id_fkey
    FOREIGN KEY (student_id) REFERENCES users(id);

-- Revert tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Skip tenants that don't have their own schema (e.g. registry-platform)
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        EXECUTE format('ALTER TABLE %I.attendance_records ADD CONSTRAINT attendance_records_student_id_fkey
            FOREIGN KEY (student_id) REFERENCES %I.users(id);', s, s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
