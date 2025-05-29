-- Verify registry:multi-child-data-model on pg

BEGIN;

SET search_path TO registry, public;

-- Verify family_members table structure
SELECT id, family_id, child_name, birth_date, grade, medical_info, 
       emergency_contact, notes, created_at, updated_at
FROM family_members
WHERE FALSE;

-- Verify new columns in related tables
SELECT family_member_id FROM enrollments WHERE FALSE;
SELECT family_member_id FROM waitlist WHERE FALSE;
SELECT family_member_id FROM attendance_records WHERE FALSE;

-- Verify indexes exist
SELECT 1 FROM pg_indexes 
WHERE schemaname = 'registry' 
AND tablename = 'family_members'
AND indexname IN ('idx_family_members_family_id', 'idx_family_members_birth_date');

ROLLBACK;