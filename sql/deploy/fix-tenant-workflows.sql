-- Deploy registry:fix-tenant-workflows to pg
-- requires: schema-based-multitennancy

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Update all tenant schemas to ensure workflows have the first_step field correctly set
DO
$$
DECLARE
    s name;
    workflow_record RECORD;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       -- For each workflow in the registry schema
       FOR workflow_record IN 
           SELECT w.id, w.slug, w.first_step 
           FROM registry.workflows w
       LOOP
           -- Update the corresponding workflow in the tenant schema with the correct first_step
           EXECUTE format('UPDATE %I.workflows 
                          SET first_step = %L 
                          WHERE slug = %L',
                         s, workflow_record.first_step, workflow_record.slug);
       END LOOP;
   END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
