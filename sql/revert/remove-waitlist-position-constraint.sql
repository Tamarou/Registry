-- Revert registry:remove-waitlist-position-constraint from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Add back the unique constraint on (session_id, position)
ALTER TABLE waitlist ADD CONSTRAINT waitlist_session_id_position_key UNIQUE (session_id, position);

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('ALTER TABLE %I.waitlist ADD CONSTRAINT waitlist_session_id_position_key UNIQUE (session_id, position);', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;