-- ABOUTME: Drop the lowercase-slug constraint.
-- ABOUTME: Rows written while it held remain valid, so nothing needs rewriting.

-- Revert registry:tenant-slug-lowercase from pg

BEGIN;

ALTER TABLE registry.tenants
  DROP CONSTRAINT IF EXISTS tenants_slug_is_lowercase;

COMMIT;
