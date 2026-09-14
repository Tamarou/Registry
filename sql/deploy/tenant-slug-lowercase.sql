-- ABOUTME: Tenant slugs must be lowercase, because every routing path already assumes it.
-- ABOUTME: A mixed-case slug breaks clone_schema partway and is unreachable besides.

-- Deploy registry:tenant-slug-lowercase to pg
-- requires: clear-template-import-stamps

BEGIN;

SET client_min_messages = 'warning';

-- A slug is a PostgreSQL schema name, a DNS label, and a routing key.
--
-- clone_schema runs set_config('search_path', dest_schema, true) on the
-- UNQUOTED name while quoting it elsewhere, so a mixed-case slug case-folds in
-- one half of a statement and not the other:
--
--   ALTER TABLE "SuperAwesomeCool".pricing_relationship_events
--     ALTER COLUMN sequence_number SET DEFAULT
--     nextval('SuperAwesomeCool.…_seq'::regclass)
--   ERROR: relation "superawesomecool.…_seq" does not exist
--
-- It dies there and leaves a half-built schema. And routing could never have
-- reached such a tenant anyway: _extract_tenant_from_subdomain lowercases the
-- Host header, and the tenant helper's regex is /\A[a-z][a-z0-9_]{0,62}\z/.
--
-- Registry::DAO::Tenant normalises on the way in; this is the backstop for
-- anything that writes the table directly.
--
-- Case only. Hyphens are also unsafe as schema names -- not every EXECUTE in
-- clone_schema quotes the identifier -- and normalize_slug converts them, but
-- the pre-existing 'registry-platform' row carries one and this change is not
-- the place to rename a tenant. #294 proposes collapsing that row into
-- registry, which removes the exception rather than grandfathering it.
ALTER TABLE registry.tenants
  ADD CONSTRAINT tenants_slug_is_lowercase CHECK (slug = lower(slug));

COMMIT;
