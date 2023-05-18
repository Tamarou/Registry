-- Deploy sacregistry:sessions to pg
-- requires: schema

BEGIN;

SET client_min_messages = 'warning';

CREATE TABLE registry.sessions (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notes TEXT NOT NULL
);

COMMIT;
