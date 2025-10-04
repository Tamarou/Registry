-- Verify registry:fix-tenant-workflows on pg

BEGIN;

-- Verify that all tenant workflows have a first_step value
DO
$$
DECLARE
    s name;
    missing_count integer;
    schema_exists boolean;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       -- Check if schema exists (it will be the slug value directly)
       SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = s) INTO schema_exists;

       IF schema_exists THEN
           EXECUTE format('SELECT COUNT(*) FROM %I.workflows WHERE first_step IS NULL', s)
           INTO missing_count;

           IF missing_count > 0 THEN
               RAISE EXCEPTION 'Tenant schema % has % workflows with NULL first_step', s, missing_count;
           END IF;
       END IF;
   END LOOP;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;
