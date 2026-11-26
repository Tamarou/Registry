-- ABOUTME: registry holds the run right to each workflow as it is imported into registry, not only those at deploy.
-- ABOUTME: Also grants any registry workflow imported since workflow-run-entitlements that has none.

-- Deploy registry:registry-run-right-at-import to pg
-- requires: solo-grants-workflow-set

BEGIN;

SET client_min_messages = 'warning';

-- workflow-run-entitlements' backfill, as a function of one slug: registry
-- holds run:<slug> through its own per-slug offer to itself, reusing a run
-- resource by name and the backfill's slug-derived ids, so that change's
-- revert removes these rows too. A right registry already holds is kept, and
-- one it held and ended is not revived: the slug-derived rows are reused, so
-- a re-import after an ending skips instead of clashing on their ids.
CREATE FUNCTION registry.registry_holds_run_right(wf_slug text) RETURNS void AS $f$
DECLARE
    run_resource uuid;
    run_offer    uuid := md5('workflow-run-entitlements/offer/' || wf_slug)::uuid;
    run_version  uuid := md5('workflow-run-entitlements/version/' || wf_slug)::uuid;
BEGIN
    IF (SELECT count(*) FROM registry.resources WHERE name = 'run:' || wf_slug) > 1 THEN
        RAISE EXCEPTION 'cannot record the run right to %: more than one run:% resource', wf_slug, wf_slug;
    END IF;
    SELECT id INTO run_resource FROM registry.resources WHERE name = 'run:' || wf_slug;

    IF run_resource IS NOT NULL AND EXISTS (
        SELECT 1 FROM registry.entitlements e
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
         WHERE e.holder_tenant_id = '00000000-0000-0000-0000-000000000000'
           AND e.state = 'active' AND e.in_effect @> now()
           AND (v.resource_id = run_resource OR run_resource IN
                (SELECT s.resource_id FROM registry.offer_version_resources s WHERE s.offer_version_id = v.id)))
    THEN
        RETURN;
    END IF;

    IF run_resource IS NULL THEN
        run_resource := md5('workflow-run-entitlements/resource/' || wf_slug)::uuid;
        INSERT INTO registry.resources (id, name, kind) VALUES (run_resource, 'run:' || wf_slug, 'unbounded');
    END IF;
    INSERT INTO registry.offers (id, name) VALUES (run_offer, 'Platform run ' || wf_slug)
        ON CONFLICT (id) DO NOTHING;
    -- A published version's plans are immutable, so its rows are written once.
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions WHERE id = run_version) THEN
        INSERT INTO registry.offer_versions
            (id, offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap,
             policies, conditions)
        VALUES (run_version, run_offer, 1, run_resource, 0, 1, 1,
                '{"refund": {"kind": "none"}}', '[{"kind": "holder_is_offerer"}]');
        INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind)
        VALUES (run_version, 'one_time', 'one_time');
        UPDATE registry.offer_versions SET published_at = now() WHERE id = run_version;
    END IF;
    INSERT INTO registry.entitlements (id, holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
    VALUES (md5('workflow-run-entitlements/entitlement/' || wf_slug)::uuid,
            '00000000-0000-0000-0000-000000000000', run_version, 'one_time', tstzrange(now(), NULL, '[)'))
        ON CONFLICT (id) DO NOTHING;
END;
$f$ LANGUAGE plpgsql;

-- clone_schema copies this trigger into each new tenant's workflows table,
-- where it does nothing: only registry's own workflows are registry's to run.
CREATE FUNCTION registry.workflow_registry_run_right() RETURNS trigger AS $t$
BEGIN
    IF TG_TABLE_SCHEMA = 'registry' THEN
        PERFORM registry.registry_holds_run_right(NEW.slug);
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

CREATE TRIGGER workflow_registry_run_right
    AFTER INSERT ON registry.workflows
    FOR EACH ROW EXECUTE FUNCTION registry.workflow_registry_run_right();

-- Workflows imported between workflow-run-entitlements and now.
-- In a DO block, so the deploy prints no result rows.
DO $$
BEGIN
    PERFORM registry.registry_holds_run_right(slug) FROM (SELECT DISTINCT slug FROM registry.workflows) w;
END $$;

COMMIT;
