-- Deploy registry:add-user-fields-for-family to pg
-- requires: users

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Add fields to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_date date;
ALTER TABLE users ADD COLUMN IF NOT EXISTS user_type text DEFAULT 'parent';
ALTER TABLE users ADD COLUMN IF NOT EXISTS grade text;

-- Add constraint for user_type
ALTER TABLE users ADD CONSTRAINT check_user_type 
    CHECK (user_type IN ('parent', 'student', 'staff', 'admin'));

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        -- Add columns
        EXECUTE format('ALTER TABLE %I.users ADD COLUMN IF NOT EXISTS birth_date date;', s);
        EXECUTE format('ALTER TABLE %I.users ADD COLUMN IF NOT EXISTS user_type text DEFAULT ''parent'';', s);
        EXECUTE format('ALTER TABLE %I.users ADD COLUMN IF NOT EXISTS grade text;', s);
        
        -- Add constraint
        EXECUTE format('ALTER TABLE %I.users ADD CONSTRAINT check_user_type 
            CHECK (user_type IN (''parent'', ''student'', ''staff'', ''admin''));', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;