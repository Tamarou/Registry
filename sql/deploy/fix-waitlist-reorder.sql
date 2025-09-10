-- Fix reorder_waitlist_positions function to avoid constraint violations
-- %project=Registry
-- %requires: waitlist-management

BEGIN;

-- This migration only applies to tenant schemas since that's where waitlist tables exist
-- The main registry schema doesn't have waitlist tables

-- Propagate to tenant schemas
DO
$$
DECLARE
    s text;
BEGIN
    FOR s IN
        SELECT schema_name FROM information_schema.schemata 
        WHERE schema_name LIKE 'tenant_%'
    LOOP
        -- Drop existing trigger and function
        EXECUTE format('DROP TRIGGER IF EXISTS reorder_waitlist_on_removal ON %I.waitlist;', s);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.reorder_waitlist_positions() CASCADE;', s);
        
        -- Create improved function
        EXECUTE format('CREATE OR REPLACE FUNCTION %I.reorder_waitlist_positions() RETURNS TRIGGER AS $func$
        BEGIN
            IF (TG_OP = ''DELETE'') OR 
               (TG_OP = ''UPDATE'' AND OLD.status = ''waiting'' AND NEW.status != ''waiting'') THEN
                
                UPDATE %I.waitlist
                SET position = position + 1000
                WHERE session_id = COALESCE(OLD.session_id, NEW.session_id)
                AND position > COALESCE(OLD.position, NEW.position)
                AND status = ''waiting'';
                
                UPDATE %I.waitlist
                SET position = subquery.new_position
                FROM (
                    SELECT id, ROW_NUMBER() OVER (ORDER BY position - 1000) as new_position
                    FROM %I.waitlist
                    WHERE session_id = COALESCE(OLD.session_id, NEW.session_id)
                    AND status = ''waiting''
                ) subquery
                WHERE %I.waitlist.id = subquery.id;
                
            END IF;
            
            RETURN NEW;
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