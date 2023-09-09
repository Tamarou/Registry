-- Deploy sacregistry:customers to pg
-- requires: schema

BEGIN;

SET client_min_messages = 'warning';

CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE IF NOT EXiSTS registry.customers (
    id   uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email citext NOT NULL UNIQUE,
    phone character varying NOT NULL,
    notes TEXT NULL
);

COMMIT;
