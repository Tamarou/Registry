-- ABOUTME: Reverts solo-grants-workflow-set: removes Solo v2, its plan, its set and the run resources it made, and Solo v1 is current again.
-- ABOUTME: Refuses while anyone holds v2, rather than deleting a sale.

-- Revert registry:solo-grants-workflow-set from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    holders text;
BEGIN
    SELECT string_agg(DISTINCT coalesce(t.slug, coalesce(e.holder_user_id, e.holder_family_member_id)::text), ', ')
      INTO holders
      FROM registry.entitlements e LEFT JOIN registry.tenants t ON t.id = e.holder_tenant_id
     WHERE e.offer_version_id = md5('solo-grants-workflow-set/version')::uuid;
    IF holders IS NOT NULL THEN
        RAISE EXCEPTION 'cannot revert solo-grants-workflow-set: tenants [%] hold Solo v2', holders;
    END IF;
END $$;

-- Published versions are append-only and superseding happens once; this
-- change's own rows are the exception, undone while the guard is lifted. v2
-- goes first (its plan and set by cascade), as one version per offer is current.
ALTER TABLE registry.offer_versions DISABLE TRIGGER offer_versions_immutable;
DELETE FROM registry.offer_versions WHERE id = md5('solo-grants-workflow-set/version')::uuid;
UPDATE registry.offer_versions SET superseded_at = NULL WHERE id = '00000000-0000-0000-0003-000000000001';
ALTER TABLE registry.offer_versions ENABLE TRIGGER offer_versions_immutable;

-- Only the run resources this change made, and only while nothing else sells them.
DELETE FROM registry.resources r
 WHERE r.name LIKE 'run:%' AND r.id = md5('solo-grants-workflow-set/resource/' || substr(r.name, 5))::uuid
   AND NOT EXISTS (SELECT 1 FROM registry.offer_versions v WHERE v.resource_id = r.id)
   AND NOT EXISTS (SELECT 1 FROM registry.offer_version_resources s WHERE s.resource_id = r.id);

COMMIT;
