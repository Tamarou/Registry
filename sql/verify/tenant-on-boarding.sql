-- Verify registry:tenant-on-boarding on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

SELECT
    id,
    name,
    slug,
    created_at
FROM tenants
WHERE FALSE;

SELECT
    tenant_id,
    description,
    created_at
FROM tenant_profiles
WHERE FALSE;

SELECT
    tenant_id,
    user_id,
    is_primary,
    created_at
FROM tenant_users
WHERE FALSE;

ROLLBACK;
