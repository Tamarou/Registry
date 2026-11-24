-- ABOUTME: Restore the interim tenant-holds-resource table, holding the operator right if registry's entitlement did.
-- ABOUTME: Removes the operator resource, offer, version and entitlement; refuses if anyone else holds the version.

-- Revert registry:operator-right-entitlement from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.entitlements
                WHERE offer_version_id = '00000000-0000-0001-0003-000000000001'
                  AND id <> '00000000-0000-0001-0004-000000000001') THEN
        RAISE EXCEPTION 'cannot revert operator-right-entitlement: an entitlement other '
                        'than the moved one is held under the operator offer version';
    END IF;
END $$;

-- As operator-right.sql made it.
CREATE TABLE registry.tenant_resources (
    tenant_id  uuid        NOT NULL,
    resource   text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, resource)
);

INSERT INTO registry.tenant_resources (tenant_id, resource)
SELECT holder_tenant_id, 'operator' FROM registry.entitlements
 WHERE id = '00000000-0000-0001-0004-000000000001'
   AND state = 'active' AND in_effect @> now();

DELETE FROM registry.entitlements WHERE id = '00000000-0000-0001-0004-000000000001';

-- Published versions are append-only; the seed's own is removed with its plan
-- (by cascade) while the guard is lifted.
ALTER TABLE registry.offer_versions DISABLE TRIGGER offer_versions_immutable;
DELETE FROM registry.offer_versions WHERE id = '00000000-0000-0001-0003-000000000001';
ALTER TABLE registry.offer_versions ENABLE TRIGGER offer_versions_immutable;

DELETE FROM registry.offers    WHERE id = '00000000-0000-0001-0002-000000000001';
DELETE FROM registry.resources WHERE id = '00000000-0000-0001-0001-000000000001';

COMMIT;
