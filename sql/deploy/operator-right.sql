-- ABOUTME: Interim storage for "tenant T holds resource R", seeded with the platform holding operator.
-- ABOUTME: The deploy migration is the bootstrap root; step 3's entitlements replace this table.

-- Deploy registry:operator-right to pg
-- requires: platform-tenant-unlinks-solo

BEGIN;

SET client_min_messages = 'warning';

-- Three surfaces cross tenants -- acting as another tenant, the job queue and
-- the cross-tenant revenue view -- and they are one resource, the operator
-- right, held by a tenant like anything else it holds.  The entitlement table
-- that will record holdings does not exist yet, so this is the smallest thing
-- that says "tenant T holds resource R".  Read only through
-- Registry::DAO::Tenant->holds, which step 3 re-points before dropping this.
--
-- No foreign key to tenants: clone_schema copies the table into every tenant
-- schema and rewrites a key to point at the tenant's own copy of tenants.
CREATE TABLE registry.tenant_resources (
    tenant_id  uuid        NOT NULL,
    resource   text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, resource)
);

-- The platform tenant holds the operator right because this row says so; no
-- code decides it from the slug or the id.
INSERT INTO registry.tenant_resources (tenant_id, resource)
VALUES ('00000000-0000-0000-0000-000000000000', 'operator');

COMMIT;
