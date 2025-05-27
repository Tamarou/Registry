-- Revert registry:add-user-fields-for-family from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Drop from tenant schemas first
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        -- Drop constraint
        EXECUTE format('ALTER TABLE %I.users DROP CONSTRAINT IF EXISTS check_user_type;', s);
        
        -- Drop columns
        EXECUTE format('ALTER TABLE %I.users DROP COLUMN IF EXISTS birth_date;', s);
        EXECUTE format('ALTER TABLE %I.users DROP COLUMN IF EXISTS user_type;', s);
        EXECUTE format('ALTER TABLE %I.users DROP COLUMN IF EXISTS grade;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Drop constraint
ALTER TABLE users DROP CONSTRAINT IF EXISTS check_user_type;

-- Drop columns
ALTER TABLE users DROP COLUMN IF EXISTS birth_date;
ALTER TABLE users DROP COLUMN IF EXISTS user_type;
ALTER TABLE users DROP COLUMN IF EXISTS grade;

COMMIT;