-- Deploy registry:program-types to pg
-- requires: schema-based-multitennancy

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Create program_types table in registry schema
CREATE TABLE IF NOT EXISTS program_types (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    slug text NOT NULL UNIQUE,
    name text NOT NULL,
    config jsonb NOT NULL DEFAULT '{}',
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp
);

-- Create update trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_program_types_updated_at ON program_types;
CREATE TRIGGER update_program_types_updated_at BEFORE UPDATE ON program_types
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Propagate to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I.program_types (
            id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
            slug text NOT NULL UNIQUE,
            name text NOT NULL,
            config jsonb NOT NULL DEFAULT ''{}'',
            created_at timestamp with time zone DEFAULT now(),
            updated_at timestamp NOT NULL DEFAULT current_timestamp
        );', s);
        
        EXECUTE format('DROP TRIGGER IF EXISTS update_program_types_updated_at ON %I.program_types;', s);
        EXECUTE format('CREATE TRIGGER update_program_types_updated_at BEFORE UPDATE ON %I.program_types
            FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Insert seed data for default program types
INSERT INTO program_types (slug, name, config) VALUES
(
    'afterschool',
    'After School Program',
    '{
        "enrollment_rules": {
            "same_session_for_siblings": true
        },
        "standard_times": {
            "monday": "15:00",
            "tuesday": "15:00",
            "wednesday": "14:00",
            "thursday": "15:00",
            "friday": "15:00"
        },
        "session_pattern": "weekly_for_x_weeks"
    }'::jsonb
),
(
    'summer-camp',
    'Summer Camp',
    '{
        "enrollment_rules": {
            "same_session_for_siblings": false
        },
        "standard_times": {
            "start": "09:00",
            "end": "15:00"
        },
        "session_pattern": "daily_for_x_days"
    }'::jsonb
);

-- Propagate seed data to tenants
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        EXECUTE format('INSERT INTO %I.program_types (slug, name, config) VALUES
        (
            ''afterschool'',
            ''After School Program'',
            ''{
                "enrollment_rules": {
                    "same_session_for_siblings": true
                },
                "standard_times": {
                    "monday": "15:00",
                    "tuesday": "15:00",
                    "wednesday": "14:00",
                    "thursday": "15:00",
                    "friday": "15:00"
                },
                "session_pattern": "weekly_for_x_weeks"
            }''::jsonb
        ),
        (
            ''summer-camp'',
            ''Summer Camp'',
            ''{
                "enrollment_rules": {
                    "same_session_for_siblings": false
                },
                "standard_times": {
                    "start": "09:00",
                    "end": "15:00"
                },
                "session_pattern": "daily_for_x_days"
            }''::jsonb
        ) ON CONFLICT (slug) DO NOTHING;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;