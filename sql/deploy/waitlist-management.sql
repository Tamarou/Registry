-- Deploy registry:waitlist-management to pg
-- requires: summer-camp-module

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Create waitlist table in registry schema
CREATE TABLE IF NOT EXISTS waitlist (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions,
    location_id uuid NOT NULL REFERENCES locations,
    student_id uuid NOT NULL REFERENCES users,
    parent_id uuid NOT NULL REFERENCES users,
    position integer NOT NULL,
    status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'offered', 'expired', 'declined')),
    offered_at timestamp with time zone,
    expires_at timestamp with time zone,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,
    
    -- Prevent duplicate waitlist entries for same session and student
    UNIQUE (session_id, student_id),
    -- Ensure position is unique within a session
    UNIQUE (session_id, position)
);

-- Create indexes for performance
CREATE INDEX idx_waitlist_session_id ON waitlist(session_id);
CREATE INDEX idx_waitlist_student_id ON waitlist(student_id);
CREATE INDEX idx_waitlist_parent_id ON waitlist(parent_id);
CREATE INDEX idx_waitlist_status ON waitlist(status);
CREATE INDEX idx_waitlist_position ON waitlist(session_id, position);

-- Create update trigger for updated_at
CREATE TRIGGER update_waitlist_updated_at BEFORE UPDATE ON waitlist
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Function to reorder positions when a waitlist entry is removed
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

-- Function to get next position for a session
CREATE OR REPLACE FUNCTION get_next_waitlist_position(p_session_id uuid) RETURNS integer AS $$
BEGIN
    RETURN COALESCE(
        (SELECT MAX(position) + 1 FROM waitlist 
         WHERE session_id = p_session_id AND status = 'waiting'),
        1
    );
END;
$$ LANGUAGE plpgsql;

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        -- Create waitlist table
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I.waitlist (
            id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
            session_id uuid NOT NULL REFERENCES %I.sessions,
            location_id uuid NOT NULL REFERENCES %I.locations,
            student_id uuid NOT NULL REFERENCES %I.users,
            parent_id uuid NOT NULL REFERENCES %I.users,
            position integer NOT NULL,
            status text NOT NULL DEFAULT ''waiting'' CHECK (status IN (''waiting'', ''offered'', ''expired'', ''declined'')),
            offered_at timestamp with time zone,
            expires_at timestamp with time zone,
            notes text,
            created_at timestamp with time zone DEFAULT now(),
            updated_at timestamp NOT NULL DEFAULT current_timestamp,
            UNIQUE (session_id, student_id),
            UNIQUE (session_id, position)
        );', s, s, s, s, s);
        
        -- Create indexes
        EXECUTE format('CREATE INDEX idx_waitlist_session_id ON %I.waitlist(session_id);', s);
        EXECUTE format('CREATE INDEX idx_waitlist_student_id ON %I.waitlist(student_id);', s);
        EXECUTE format('CREATE INDEX idx_waitlist_parent_id ON %I.waitlist(parent_id);', s);
        EXECUTE format('CREATE INDEX idx_waitlist_status ON %I.waitlist(status);', s);
        EXECUTE format('CREATE INDEX idx_waitlist_position ON %I.waitlist(session_id, position);', s);
        
        -- Create trigger
        EXECUTE format('CREATE TRIGGER update_waitlist_updated_at BEFORE UPDATE ON %I.waitlist
            FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();', s);
        
        -- Create reorder function
        EXECUTE format('CREATE OR REPLACE FUNCTION %I.reorder_waitlist_positions() RETURNS TRIGGER AS $$
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
        $$ LANGUAGE plpgsql;', s, s);
        
        -- Create reorder trigger
        EXECUTE format('CREATE TRIGGER reorder_waitlist_on_removal
            AFTER UPDATE OR DELETE ON %I.waitlist
            FOR EACH ROW
            EXECUTE FUNCTION %I.reorder_waitlist_positions();', s, s);
        
        -- Create position function
        EXECUTE format('CREATE OR REPLACE FUNCTION %I.get_next_waitlist_position(p_session_id uuid) RETURNS integer AS $$
        BEGIN
            RETURN COALESCE(
                (SELECT MAX(position) + 1 FROM %I.waitlist 
                 WHERE session_id = p_session_id AND status = ''waiting''),
                1
            );
        END;
        $$ LANGUAGE plpgsql;', s, s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;