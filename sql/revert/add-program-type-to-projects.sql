-- Revert registry:add-program-type-to-projects from pg

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
        EXECUTE format('ALTER TABLE %I.projects DROP CONSTRAINT IF EXISTS fk_projects_program_type;', s);
        
        -- Drop column
        EXECUTE format('ALTER TABLE %I.projects DROP COLUMN IF EXISTS program_type_slug;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Drop constraint
ALTER TABLE projects DROP CONSTRAINT IF EXISTS fk_projects_program_type;

-- Drop column
ALTER TABLE projects DROP COLUMN IF EXISTS program_type_slug;

COMMIT;