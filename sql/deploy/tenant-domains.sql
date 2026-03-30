-- Deploy registry:tenant-domains to pg
-- requires: notifications-and-preferences

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

CREATE TABLE IF NOT EXISTS tenant_domains (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    domain text NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'verified', 'failed')),
    is_primary boolean NOT NULL DEFAULT false,
    render_domain_id text,
    verification_error text,
    verified_at timestamptz,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_tenant_domains_domain ON tenant_domains(domain);
CREATE INDEX idx_tenant_domains_tenant_id ON tenant_domains(tenant_id);

-- At most one primary domain per tenant
CREATE UNIQUE INDEX idx_tenant_domains_primary
    ON tenant_domains(tenant_id) WHERE is_primary = true;

-- Keep updated_at current on every row change
CREATE OR REPLACE FUNCTION registry.tenant_domains_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER tenant_domains_updated_at
    BEFORE UPDATE ON tenant_domains
    FOR EACH ROW EXECUTE FUNCTION registry.tenant_domains_updated_at();

COMMIT;
