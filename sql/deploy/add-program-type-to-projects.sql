-- Deploy registry:add-program-type-to-projects to pg
-- requires: program-types

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Add program_type_slug to projects
ALTER TABLE projects ADD COLUMN IF NOT EXISTS program_type_slug text;

-- Add foreign key constraint
ALTER TABLE projects 
ADD CONSTRAINT fk_projects_program_type 
FOREIGN KEY (program_type_slug) 
REFERENCES program_types(slug);

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Add column
        EXECUTE format('ALTER TABLE %I.projects ADD COLUMN IF NOT EXISTS program_type_slug text;', s);
        
        -- Add foreign key
        EXECUTE format('ALTER TABLE %I.projects 
            ADD CONSTRAINT fk_projects_program_type 
            FOREIGN KEY (program_type_slug) 
            REFERENCES %I.program_types(slug);', s, s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;