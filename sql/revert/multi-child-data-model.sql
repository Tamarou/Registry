-- Revert registry:multi-child-data-model from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Drop columns from related tables first
ALTER TABLE attendance_records DROP COLUMN IF EXISTS family_member_id;
ALTER TABLE waitlist DROP COLUMN IF EXISTS family_member_id;
ALTER TABLE enrollments DROP COLUMN IF EXISTS family_member_id;

-- Drop from tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        -- Drop columns
        EXECUTE format('ALTER TABLE %I.attendance_records DROP COLUMN IF EXISTS family_member_id;', s);
        EXECUTE format('ALTER TABLE %I.waitlist DROP COLUMN IF EXISTS family_member_id;', s);
        EXECUTE format('ALTER TABLE %I.enrollments DROP COLUMN IF EXISTS family_member_id;', s);
        
        -- Drop table
        EXECUTE format('DROP TABLE IF EXISTS %I.family_members CASCADE;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Drop from registry schema
DROP TABLE IF EXISTS family_members CASCADE;

COMMIT;