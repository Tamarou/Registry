-- ABOUTME: Reverts workflow-run-entitlements: drops the run-right guard everywhere and registry's backfilled rights.
-- ABOUTME: Removes only rows whose ids derive from their slug; the bootstrap's five product-design rights stay.

-- Revert registry:workflow-run-entitlements from pg

BEGIN;

SET client_min_messages = 'warning';

-- No function is rebuilt here: the guard is new, so each copy clone_schema
-- gave a tenant since deploy is dropped by name in its own schema.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.entitlements', s)) IS NULL;
        EXECUTE format('DROP TRIGGER IF EXISTS entitlement_one_run_right ON %I.entitlements', s);
        IF s != 'registry' THEN
            EXECUTE format('DROP FUNCTION IF EXISTS %I.entitlement_one_run_right()', s);
        END IF;
    END LOOP;
END $$;

DROP FUNCTION registry.entitlement_one_run_right();

-- The backfill's rows: each id is the slug's derived id for its kind.
CREATE TEMPORARY TABLE backfilled ON COMMIT DROP AS
SELECT substr(r.name, 5) AS slug FROM registry.resources r WHERE r.name LIKE 'run:%'
UNION
SELECT substr(o.name, 14) FROM registry.offers o WHERE o.name LIKE 'Platform run %';

-- Another holder's entitlement under a backfilled version is not the backfill's: refuse, never delete it.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.entitlements e JOIN backfilled b
                 ON e.offer_version_id = md5('workflow-run-entitlements/version/' || b.slug)::uuid
                WHERE e.id <> md5('workflow-run-entitlements/entitlement/' || b.slug)::uuid) THEN
        RAISE EXCEPTION 'cannot revert workflow-run-entitlements: an entitlement other than the backfill''s '
                        'is held under a backfilled run-right version';
    END IF;
END $$;

DELETE FROM registry.entitlements e USING backfilled b
 WHERE e.id = md5('workflow-run-entitlements/entitlement/' || b.slug)::uuid;

-- Published versions are append-only; the backfill's own are removed with
-- their plans (by cascade) while the guard is lifted, as the bootstrap's are.
ALTER TABLE registry.offer_versions DISABLE TRIGGER offer_versions_immutable;
DELETE FROM registry.offer_versions v USING backfilled b
 WHERE v.id = md5('workflow-run-entitlements/version/' || b.slug)::uuid;
ALTER TABLE registry.offer_versions ENABLE TRIGGER offer_versions_immutable;

DELETE FROM registry.offers o USING backfilled b
 WHERE o.id = md5('workflow-run-entitlements/offer/' || b.slug)::uuid;
-- A run resource another offer now sells stays: it is that offer's too. A
-- redeploy finds it by name and grants registry its right again.
DELETE FROM registry.resources r USING backfilled b
 WHERE r.id = md5('workflow-run-entitlements/resource/' || b.slug)::uuid
   AND NOT EXISTS (SELECT 1 FROM registry.offer_versions v WHERE v.resource_id = r.id)
   AND NOT EXISTS (SELECT 1 FROM registry.offer_version_resources s WHERE s.resource_id = r.id);

COMMIT;
