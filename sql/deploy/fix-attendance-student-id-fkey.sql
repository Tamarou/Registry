-- Deploy registry:fix-attendance-student-id-fkey to pg
-- requires: attendance-tracking

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove the foreign key constraint from attendance_records.student_id.
-- The multi-child data model uses family_member IDs as student references,
-- but the original schema constrained student_id to reference users. The
-- family_member_id column provides the typed FK reference for family-member
-- students; student_id is now polymorphic (family_member.id or users.id).
ALTER TABLE attendance_records DROP CONSTRAINT IF EXISTS attendance_records_student_id_fkey;

-- Propagate to tenant schemas
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
        EXECUTE format('ALTER TABLE %I.attendance_records DROP CONSTRAINT IF EXISTS attendance_records_student_id_fkey;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
