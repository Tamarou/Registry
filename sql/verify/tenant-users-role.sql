-- ABOUTME: Verify every membership has a role, and the role is one check_user_type allows.
-- ABOUTME: NOT NULL is load-bearing: a membership without a role has no defined authority.

-- Verify registry:tenant-users-role on pg

BEGIN;

SELECT tenant_id, user_id, role
  FROM registry.tenant_users
 WHERE FALSE;

DO $$
BEGIN
    IF (SELECT is_nullable FROM information_schema.columns
         WHERE table_schema = 'registry' AND table_name = 'tenant_users'
           AND column_name = 'role') <> 'NO' THEN
        RAISE EXCEPTION 'registry.tenant_users.role must be NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'check_tenant_user_role'
           AND conrelid = 'registry.tenant_users'::regclass
    ) THEN
        RAISE EXCEPTION 'registry.tenant_users.role has no check_tenant_user_role';
    END IF;
END $$;

ROLLBACK;
