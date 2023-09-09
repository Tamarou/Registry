-- Deploy sacregistry:locations to pg
-- requires: sessions
-- requires: schema

BEGIN;

SET client_min_messages = 'warning';

CREATE TABLE registry.locations (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    address TEXT NOT NULL,
    notes TEXT NULL
);

ALTER TABLE registry.sessions
ADD COLUMN IF NOT EXISTS location_id uuid
REFERENCES registry.locations(id);

COMMIT;
