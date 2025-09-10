-- Deploy registry:fix-waitlist-reorder-v2 to pg
-- requires: fix-waitlist-reorder

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Fix the reorder function to properly avoid unique constraint violations
-- by using a more robust reordering strategy

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
        -- Drop existing trigger and function first
        EXECUTE format('DROP TRIGGER IF EXISTS reorder_waitlist_on_removal ON %I.waitlist;', s);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.reorder_waitlist_positions() CASCADE;', s);
        
        -- Create improved function that avoids constraint violations
        EXECUTE format('CREATE OR REPLACE FUNCTION %I.reorder_waitlist_positions() RETURNS TRIGGER AS $func$
        BEGIN
            -- Only reorder if status changed away from waiting or record is deleted
            IF (TG_OP = ''DELETE'') OR 
               (TG_OP = ''UPDATE'' AND OLD.status = ''waiting'' AND NEW.status != ''waiting'') THEN
                
                -- Use a three-step process to avoid unique constraint violations:
                -- 1. Move all affected positions to negative values temporarily  
                -- 2. Recompute correct positions
                -- 3. Apply the new positions
                
                -- Step 1: Move all waiting entries after the removed position to negative temporary values
                UPDATE %I.waitlist
                SET position = -position - 1000000
                WHERE session_id = COALESCE(OLD.session_id, NEW.session_id)
                AND position > COALESCE(OLD.position, NEW.position)
                AND status = ''waiting'';
                
                -- Step 2: Recompute positions for the temporarily moved entries
                UPDATE %I.waitlist
                SET position = subquery.new_position
                FROM (
                    SELECT id, 
                           COALESCE(OLD.position, NEW.position) + ROW_NUMBER() OVER (ORDER BY -position) - 1 as new_position
                    FROM %I.waitlist
                    WHERE session_id = COALESCE(OLD.session_id, NEW.session_id)
                    AND position < 0
                    AND status = ''waiting''
                ) subquery
                WHERE %I.waitlist.id = subquery.id;
                
            END IF;
            
            RETURN COALESCE(NEW, OLD);
        END;
        $func$ LANGUAGE plpgsql;', s, s, s, s, s);
        
        -- Recreate trigger
        EXECUTE format('CREATE TRIGGER reorder_waitlist_on_removal
            AFTER UPDATE OR DELETE ON %I.waitlist
            FOR EACH ROW
            EXECUTE FUNCTION %I.reorder_waitlist_positions();', s, s);
            
    END LOOP;
END;
$$;

COMMIT;