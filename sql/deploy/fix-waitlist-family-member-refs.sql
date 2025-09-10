-- Deploy registry:fix-waitlist-family-member-refs to pg
-- requires: remove-student-id-foreign-key

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove the foreign key constraint from waitlist.student_id to users table
-- since waitlist.student_id should reference family_members table for family member students
ALTER TABLE waitlist DROP CONSTRAINT IF EXISTS waitlist_student_id_fkey;

-- For existing waitlist entries, we need to convert student_id from users to family_members
-- Since waitlist is for family members, student_id should reference family_members table
-- This is a data migration that may need manual review in production
-- For now, we'll just remove the constraint and update the DAO to handle this properly

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('ALTER TABLE %I.waitlist DROP CONSTRAINT IF EXISTS waitlist_student_id_fkey;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;