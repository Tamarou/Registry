-- Deploy sacregistry:students to pg
-- requires: schema
-- requires: customers
-- requires: sessions

BEGIN;

CREATE TABLE IF NOT EXISTS registry.students (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    metadata JSONB NULL,
    notes TEXT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS registry.sessions_students (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id uuid NOT NULL,
    student_id uuid NOT NULL,
    marked_present BOOL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE
);

COMMIT;
