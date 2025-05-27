-- Revert registry:waitlist-management from pg

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
        -- Drop functions
        EXECUTE format('DROP FUNCTION IF EXISTS %I.get_next_waitlist_position(uuid);', s);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.reorder_waitlist_positions() CASCADE;', s);
        
        -- Drop table (will cascade drop triggers and indexes)
        EXECUTE format('DROP TABLE IF EXISTS %I.waitlist CASCADE;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Drop functions
DROP FUNCTION IF EXISTS get_next_waitlist_position(uuid);
DROP FUNCTION IF EXISTS reorder_waitlist_positions() CASCADE;

-- Drop from registry schema
DROP TABLE IF EXISTS waitlist CASCADE;

COMMIT;