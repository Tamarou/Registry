-- Verify registry:add-user-fields-for-family on pg

BEGIN;

SET search_path TO registry, public;

-- Verify columns exist
SELECT birth_date, user_type, grade FROM users WHERE FALSE;

-- Verify constraint exists
SELECT 1 FROM pg_constraint 
WHERE conname = 'check_user_type';

ROLLBACK;