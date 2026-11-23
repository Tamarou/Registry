-- ABOUTME: A membership carries its own role, so authority is read per tenant (ADR 005, ruling 4).
-- ABOUTME: Backfills each membership from its user's user_type, so no existing membership changes meaning.

-- Deploy registry:tenant-users-role to pg
-- requires: collapse-platform-tenant

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- users.user_type is global: Morgan is 'admin' everywhere he is a member,
-- which is the escalation ruling 4 closes -- a studio's admin added to the
-- `registry` tenant as support would otherwise be a platform admin.  The role
-- belongs to the membership.
ALTER TABLE tenant_users ADD COLUMN role text;

-- Every existing membership keeps today's meaning: whatever its user is.
UPDATE tenant_users tu
   SET role = u.user_type
  FROM users u
 WHERE u.id = tu.user_id;

-- The same values check_user_type allows.
ALTER TABLE tenant_users
    ALTER COLUMN role SET NOT NULL,
    ADD CONSTRAINT check_tenant_user_role
        CHECK (role = ANY (ARRAY['parent'::text, 'student'::text, 'staff'::text, 'admin'::text]));

-- A row written without a role grants nothing.  Tenant->add_user names the
-- role (the user's user_type unless told otherwise); this is the floor for a
-- write that does not.
ALTER TABLE tenant_users ALTER COLUMN role SET DEFAULT 'parent';

COMMIT;
