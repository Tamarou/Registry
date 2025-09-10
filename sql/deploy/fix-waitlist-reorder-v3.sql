-- Deploy registry:fix-waitlist-reorder-v3 to pg
-- requires: fix-waitlist-reorder-v2

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Remove the problematic trigger entirely and handle position reordering in application code
-- This is a more reliable approach than trying to fix the constraint violations in the trigger

-- This migration applies to all schemas that have waitlist tables
DO
$$
DECLARE
    s text;
BEGIN
    -- Check all schemas for waitlist tables
    FOR s IN
        SELECT table_schema FROM information_schema.tables 
        WHERE table_name = 'waitlist'
        GROUP BY table_schema
    LOOP
        -- Drop the problematic trigger and function
        EXECUTE format('DROP TRIGGER IF EXISTS reorder_waitlist_on_removal ON %I.waitlist;', s);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.reorder_waitlist_positions() CASCADE;', s);
            
    END LOOP;
END;
$$;

COMMIT;