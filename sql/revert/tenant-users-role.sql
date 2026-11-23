-- ABOUTME: Drop the membership role; authority falls back to whatever reads users.user_type.
-- ABOUTME: Any membership role that differed from its user's user_type is lost.

-- Revert registry:tenant-users-role from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE tenant_users DROP COLUMN IF EXISTS role;

COMMIT;
