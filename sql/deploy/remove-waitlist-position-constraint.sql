-- Deploy registry:remove-waitlist-position-constraint to pg
-- requires: fix-waitlist-reorder-v3

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove the problematic unique constraint on (session_id, position)
-- Position should only be used for ordering within 'waiting' status, not globally unique
ALTER TABLE waitlist DROP CONSTRAINT waitlist_session_id_position_key;

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('ALTER TABLE %I.waitlist DROP CONSTRAINT waitlist_session_id_position_key;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;