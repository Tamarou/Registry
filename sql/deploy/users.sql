-- Deploy registry:users to pg

BEGIN;

SET client_min_messages = 'warning';

CREATE SCHEMA registry;
GRANT SELECT ON ALL TABLES IN SCHEMA registry TO PUBLIC;

SET search_path TO registry,public;

CREATE TABLE IF NOT EXISTS users (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    passhash TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_profiles (
    user_id UUID PRIMARY KEY references users(id),
    data JSONB, -- we probably want to do something more strutured here but this will do for now
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

COMMIT;
