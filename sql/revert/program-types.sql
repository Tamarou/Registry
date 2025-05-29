-- Revert registry:program-types from pg

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
        EXECUTE format('DROP TABLE IF EXISTS %I.program_types CASCADE;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Drop from registry schema
DROP TABLE IF EXISTS program_types CASCADE;

COMMIT;