-- Verify registry:fix-tenant-workflows on pg

BEGIN;

-- Verify that all tenant workflows have a first_step value
DO
$$
DECLARE
    s name;
    missing_count integer;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       EXECUTE format('SELECT COUNT(*) FROM %I.workflows WHERE first_step IS NULL', s)
       INTO missing_count;
       
       IF missing_count > 0 THEN
           RAISE EXCEPTION 'Tenant schema % has % workflows with NULL first_step', s, missing_count;
       END IF;
   END LOOP;
END;
$$ LANGUAGE plpgsql;

ROLLBACK;
