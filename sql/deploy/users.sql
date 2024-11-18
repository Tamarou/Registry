-- Deploy registry:users to pg

BEGIN;

SET client_min_messages = 'warning';

CREATE SCHEMA registry;
GRANT SELECT ON ALL TABLES IN SCHEMA registry TO public;

SET search_path TO registry, public;

CREATE TABLE IF NOT EXISTS users (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    username text UNIQUE NOT NULL,
    passhash text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_profiles (
    user_id uuid PRIMARY KEY REFERENCES users (id),
    email text UNIQUE NOT NULL,
    name text NOT NULL,
    phone text NULL,
    data jsonb, -- we probably want to do something more strutured here
    created_at timestamp with time zone DEFAULT now()
);

COMMIT;
