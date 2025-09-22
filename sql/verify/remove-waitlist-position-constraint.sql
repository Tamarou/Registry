-- Verify registry:remove-waitlist-position-constraint on pg

BEGIN;

SET search_path TO registry, public;

-- Verify the unique constraint on (session_id, position) has been removed
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'waitlist_session_id_position_key'
        AND table_name = 'waitlist'
        AND table_schema = 'registry'
    ) THEN
        RAISE EXCEPTION 'Constraint waitlist_session_id_position_key still exists';
    END IF;
END $$;

ROLLBACK;