-- Revert registry:tenant-on-boarding from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP TABLE IF EXISTS tenant_users;
DROP TABLE IF EXISTS tenant_profiles;
DROP TABLE IF EXISTS tenants;

COMMIT;
