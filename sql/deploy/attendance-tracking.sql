-- Deploy registry:attendance-tracking to pg
-- requires: summer-camp-module

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Create attendance_records table in registry schema
CREATE TABLE IF NOT EXISTS attendance_records (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    event_id uuid NOT NULL REFERENCES events,
    student_id uuid NOT NULL REFERENCES users,
    status text NOT NULL CHECK (status IN ('present', 'absent')),
    marked_at timestamp with time zone NOT NULL DEFAULT now(),
    marked_by uuid NOT NULL REFERENCES users,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,
    
    -- Prevent duplicate attendance records for same event and student
    UNIQUE (event_id, student_id)
);

-- Create indexes for performance
CREATE INDEX idx_attendance_event_id ON attendance_records(event_id);
CREATE INDEX idx_attendance_student_id ON attendance_records(student_id);
CREATE INDEX idx_attendance_marked_at ON attendance_records(marked_at);
CREATE INDEX idx_attendance_status ON attendance_records(status);

-- Create update function if it doesn't exist (defined in program-types.sql)
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create update trigger for updated_at
CREATE TRIGGER update_attendance_records_updated_at BEFORE UPDATE ON attendance_records
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Create attendance_records table
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I.attendance_records (
            id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
            event_id uuid NOT NULL REFERENCES %I.events,
            student_id uuid NOT NULL REFERENCES %I.users,
            status text NOT NULL CHECK (status IN (''present'', ''absent'')),
            marked_at timestamp with time zone NOT NULL DEFAULT now(),
            marked_by uuid NOT NULL REFERENCES %I.users,
            notes text,
            created_at timestamp with time zone DEFAULT now(),
            updated_at timestamp NOT NULL DEFAULT current_timestamp,
            UNIQUE (event_id, student_id)
        );', s, s, s, s);
        
        -- Create indexes
        EXECUTE format('CREATE INDEX idx_attendance_event_id ON %I.attendance_records(event_id);', s);
        EXECUTE format('CREATE INDEX idx_attendance_student_id ON %I.attendance_records(student_id);', s);
        EXECUTE format('CREATE INDEX idx_attendance_marked_at ON %I.attendance_records(marked_at);', s);
        EXECUTE format('CREATE INDEX idx_attendance_status ON %I.attendance_records(status);', s);
        
        -- Create trigger
        EXECUTE format('CREATE TRIGGER update_attendance_records_updated_at BEFORE UPDATE ON %I.attendance_records
            FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;