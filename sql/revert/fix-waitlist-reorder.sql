-- Revert fix-waitlist-reorder

BEGIN;

-- Restore original function
DROP TRIGGER IF EXISTS reorder_waitlist_on_removal ON waitlist;
DROP FUNCTION IF EXISTS reorder_waitlist_positions();

-- Create original function
CREATE OR REPLACE FUNCTION reorder_waitlist_positions() RETURNS TRIGGER AS $$
BEGIN
    -- Only reorder if status changed away from 'waiting' or record is deleted
    IF (TG_OP = 'DELETE') OR 
       (TG_OP = 'UPDATE' AND OLD.status = 'waiting' AND NEW.status != 'waiting') THEN
        -- Reorder remaining waiting entries
        UPDATE waitlist
        SET position = position - 1
        WHERE session_id = COALESCE(OLD.session_id, NEW.session_id)
        AND position > COALESCE(OLD.position, NEW.position)
        AND status = 'waiting';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for automatic position reordering
CREATE TRIGGER reorder_waitlist_on_removal
    AFTER UPDATE OR DELETE ON waitlist
    FOR EACH ROW
    EXECUTE FUNCTION reorder_waitlist_positions();

-- Revert in tenant schemas
DO
$$
DECLARE
    s text;
BEGIN
    FOR s IN
        SELECT schema_name FROM information_schema.schemata 
        WHERE schema_name LIKE 'tenant_%'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS reorder_waitlist_on_removal ON %I.waitlist;', s);
        EXECUTE format('DROP FUNCTION IF EXISTS %I.reorder_waitlist_positions() CASCADE;', s);
        
        EXECUTE format('CREATE OR REPLACE FUNCTION %I.reorder_waitlist_positions() RETURNS TRIGGER AS $func$
        BEGIN
            IF (TG_OP = ''DELETE'') OR 
               (TG_OP = ''UPDATE'' AND OLD.status = ''waiting'' AND NEW.status != ''waiting'') THEN
                UPDATE %I.waitlist
                SET position = position - 1
                WHERE session_id = COALESCE(OLD.session_id, NEW.session_id)
                AND position > COALESCE(OLD.position, NEW.position)
                AND status = ''waiting'';
            END IF;
            
            RETURN NEW;
        END;
        $func$ LANGUAGE plpgsql;', s, s);
        
        EXECUTE format('CREATE TRIGGER reorder_waitlist_on_removal
            AFTER UPDATE OR DELETE ON %I.waitlist
            FOR EACH ROW
            EXECUTE FUNCTION %I.reorder_waitlist_positions();', s, s);
    END LOOP;
END;
$$;

COMMIT;