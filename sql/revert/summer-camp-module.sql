-- Revert registry:summer-camp-module from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Drop new tables
DROP TABLE IF EXISTS enrollments;
DROP TABLE IF EXISTS pricing;
DROP TABLE IF EXISTS session_teachers;

-- Revert changes from sessions table
ALTER TABLE sessions DROP COLUMN IF EXISTS session_type;
ALTER TABLE sessions DROP COLUMN IF EXISTS start_date;
ALTER TABLE sessions DROP COLUMN IF EXISTS end_date;
ALTER TABLE sessions DROP COLUMN IF EXISTS status;

-- Revert changes from events table
ALTER TABLE events DROP COLUMN IF EXISTS min_age;
ALTER TABLE events DROP COLUMN IF EXISTS max_age;
ALTER TABLE events DROP COLUMN IF EXISTS capacity;

-- Revert changes from locations table
ALTER TABLE locations DROP COLUMN IF EXISTS address_street;
ALTER TABLE locations DROP COLUMN IF EXISTS address_city;
ALTER TABLE locations DROP COLUMN IF EXISTS address_state;
ALTER TABLE locations DROP COLUMN IF EXISTS address_zip;
ALTER TABLE locations DROP COLUMN IF EXISTS capacity;
ALTER TABLE locations DROP COLUMN IF EXISTS contact_info;
ALTER TABLE locations DROP COLUMN IF EXISTS facilities;
ALTER TABLE locations DROP COLUMN IF EXISTS latitude;
ALTER TABLE locations DROP COLUMN IF EXISTS longitude;

-- Propagate schema changes to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants LOOP
       -- Drop new tables
       EXECUTE format('DROP TABLE IF EXISTS %I.enrollments;', s);
       EXECUTE format('DROP TABLE IF EXISTS %I.pricing;', s);
       EXECUTE format('DROP TABLE IF EXISTS %I.session_teachers;', s);

       -- Revert changes from sessions table
       EXECUTE format('ALTER TABLE %I.sessions DROP COLUMN IF EXISTS session_type;', s);
       EXECUTE format('ALTER TABLE %I.sessions DROP COLUMN IF EXISTS start_date;', s);
       EXECUTE format('ALTER TABLE %I.sessions DROP COLUMN IF EXISTS end_date;', s);
       EXECUTE format('ALTER TABLE %I.sessions DROP COLUMN IF EXISTS status;', s);

       -- Revert changes from events table
       EXECUTE format('ALTER TABLE %I.events DROP COLUMN IF EXISTS min_age;', s);
       EXECUTE format('ALTER TABLE %I.events DROP COLUMN IF EXISTS max_age;', s);
       EXECUTE format('ALTER TABLE %I.events DROP COLUMN IF EXISTS capacity;', s);

       -- Revert changes from locations table
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS address_street;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS address_city;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS address_state;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS address_zip;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS capacity;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS contact_info;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS facilities;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS latitude;', s);
       EXECUTE format('ALTER TABLE %I.locations DROP COLUMN IF EXISTS longitude;', s);
   END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
