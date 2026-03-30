-- Revert registry:tenant-domains from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP TABLE IF EXISTS tenant_domains CASCADE;
DROP FUNCTION IF EXISTS registry.tenant_domains_updated_at();

COMMIT;
