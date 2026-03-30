-- Verify registry:tenant-domains on pg

BEGIN;

SET search_path TO registry, public;

SELECT id, tenant_id, domain, status, is_primary, render_domain_id,
       verification_error, verified_at, created_at, updated_at
  FROM tenant_domains WHERE FALSE;

ROLLBACK;
