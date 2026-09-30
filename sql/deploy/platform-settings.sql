-- ABOUTME: Platform-level configuration Alex can see and change without a deploy.
-- ABOUTME: Seeded with its keys and descriptions, because a settings table you must know the keys of is not visible.

-- Deploy registry:platform-settings to pg
-- requires: payments-carry-instalments

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Pillar 5 of PriceOps is that changes go through tools against a single source
-- of truth, and #427 measures the platform as having none: rates are psql and
-- new plans are migrations. This is the first row of that table rather than a
-- table for one setting -- the shape a second setting lands in without another
-- migration.
--
-- Rows are SEEDED with their description and default, not created on first
-- write. A key/value store Alex has to already know the keys of is not
-- configuration he can see; it is configuration somebody told him about once.
-- `registry platform settings` lists this table, so what exists is discoverable
-- from the thing itself.
CREATE TABLE IF NOT EXISTS platform_settings (
    key          text PRIMARY KEY,

    -- NULL is NOT SET: the platform has no opinion and the code's default
    -- applies. That is a different thing from any value the key can hold, and
    -- collapsing the two is the bug this column's nullability exists to avoid --
    -- for the first key here, unset means 90 days and '0' means never, and
    -- reading either as the other silently switches a report on or off.
    value        text,

    -- What the key does and what happens when it is not set, in a sentence Alex
    -- can read. Stored rather than living in a manual, because the manual is not
    -- what he will have open.
    description  text NOT NULL,
    default_note text NOT NULL,

    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid REFERENCES users(id)
);

COMMENT ON COLUMN platform_settings.value IS
    'NULL means not set: the code default applies. Distinct from any value the key accepts.';

INSERT INTO platform_settings (key, value, description, default_note)
VALUES (
    'inert_tenant_days',
    NULL,
    'How long a tenant may sit unused before `registry tenant inert` reports it as abandoned. Set to 0 for never.',
    'Not set: 90 days.'
)
ON CONFLICT (key) DO NOTHING;

COMMIT;
