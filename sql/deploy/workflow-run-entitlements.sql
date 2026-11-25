-- ABOUTME: The right to run a workflow is a run:<slug> resource; registry holds one for each workflow it holds.
-- ABOUTME: At most one in-effect run right per holder per workflow; refuses while a studio holds workflow copies.

-- Deploy registry:workflow-run-entitlements to pg
-- requires: offer-version-resource-set

BEGIN;

SET client_min_messages = 'warning';

-- A studio's run rights come from a platform Solo version that lists them (ADR
-- 004 ruling (a)), published through offer-publishing, not here; day one
-- sells a single-resource Solo and no holder is moved. So a studio holding
-- copies today would be left without the rights it has: refuse instead,
-- naming each. Production has no studio tenants.
DO $$
DECLARE
    s name;
    holding text[] := '{}';
    n bigint;
BEGIN
    FOR s IN SELECT slug::name FROM registry.tenants WHERE slug != 'registry' ORDER BY slug LOOP
        CONTINUE WHEN to_regclass(format('%I.workflows', s)) IS NULL;
        EXECUTE format('SELECT count(*) FROM %I.workflows', s) INTO n;
        IF n > 0 THEN holding := holding || s::text; END IF;
    END LOOP;
    IF cardinality(holding) > 0 THEN
        RAISE EXCEPTION 'cannot record workflow run rights: studio tenants % hold workflow copies, and no '
                        'platform offer grants a studio its run rights yet. Re-create each through '
                        'signup once one does', array_to_string(holding, ', ');
    END IF;
END $$;

-- registry holds a run right for each workflow it holds, through its offer to
-- itself per slug, as bootstrap-platform-offers seeded the five product-design
-- ones: reused, never duplicated. New rows take ids derived from the slug, so
-- a redeploy writes the same rows and the revert finds exactly these.
DO $$
DECLARE
    w record;
    run_resource uuid;
    run_version uuid;
BEGIN
    FOR w IN SELECT DISTINCT slug FROM registry.workflows ORDER BY slug LOOP
        IF (SELECT count(*) FROM registry.resources WHERE name = 'run:' || w.slug) > 1 THEN
            RAISE EXCEPTION 'cannot record the run right to %: more than one run:% resource', w.slug, w.slug;
        END IF;
        SELECT id INTO run_resource FROM registry.resources WHERE name = 'run:' || w.slug;

        CONTINUE WHEN run_resource IS NOT NULL AND EXISTS (
            SELECT 1 FROM registry.entitlements e
              JOIN registry.offer_versions v ON v.id = e.offer_version_id
             WHERE e.holder_tenant_id = '00000000-0000-0000-0000-000000000000'
               AND e.state = 'active' AND e.in_effect @> now()
               AND (v.resource_id = run_resource OR run_resource IN
                    (SELECT s.resource_id FROM registry.offer_version_resources s WHERE s.offer_version_id = v.id)));

        IF run_resource IS NULL THEN
            run_resource := md5('workflow-run-entitlements/resource/' || w.slug)::uuid;
            INSERT INTO registry.resources (id, name, kind) VALUES (run_resource, 'run:' || w.slug, 'unbounded');
        END IF;
        run_version := md5('workflow-run-entitlements/version/' || w.slug)::uuid;
        INSERT INTO registry.offers (id, name)
        VALUES (md5('workflow-run-entitlements/offer/' || w.slug)::uuid, 'Platform run ' || w.slug);
        INSERT INTO registry.offer_versions
            (id, offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap,
             policies, conditions)
        VALUES (run_version, md5('workflow-run-entitlements/offer/' || w.slug)::uuid, 1, run_resource, 0, 1, 1,
                '{"refund": {"kind": "none"}}', '[{"kind": "holder_is_offerer"}]');
        INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind)
        VALUES (run_version, 'one_time', 'one_time');
        UPDATE registry.offer_versions SET published_at = now() WHERE id = run_version;
        INSERT INTO registry.entitlements (id, holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
        VALUES (md5('workflow-run-entitlements/entitlement/' || w.slug)::uuid,
                '00000000-0000-0000-0000-000000000000', run_version, 'one_time', tstzrange(now(), NULL, '[)'));
    END LOOP;
END $$;

-- At most one in-effect run right per holder per workflow, whatever the plan:
-- priceops-entitlement-one-phase covers only schedule plans of one offer. In
-- effect is 01a20448-1177's predicate (active, period overlapping), and every
-- ending closes the period, so an ended right never blocks its successor. A
-- trigger, as an EXCLUDE cannot join to what a version buys; the per-holder
-- advisory lock makes two concurrent grants take turns. clone_schema copies
-- it into tenant schemas, where a holder never holds platform rights, so the
-- copy does nothing: the rule is registry's.
CREATE FUNCTION registry.entitlement_one_run_right() RETURNS trigger AS $t$
DECLARE
    holder uuid := coalesce(NEW.holder_user_id, NEW.holder_family_member_id, NEW.holder_tenant_id);
    taken text;
BEGIN
    IF TG_TABLE_SCHEMA <> 'registry' OR NEW.state <> 'active' THEN
        RETURN NEW;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('run_right:' || holder, 0));
    SELECT r.name INTO taken
      FROM registry.offer_versions nv
      JOIN registry.resources r ON r.name LIKE 'run:%'
       AND (r.id = nv.resource_id OR r.id IN
            (SELECT s.resource_id FROM registry.offer_version_resources s WHERE s.offer_version_id = nv.id))
     WHERE nv.id = NEW.offer_version_id
       AND EXISTS (
           SELECT 1 FROM registry.entitlements e
             JOIN registry.offer_versions v ON v.id = e.offer_version_id
            WHERE coalesce(e.holder_user_id, e.holder_family_member_id, e.holder_tenant_id) = holder
              AND e.id <> NEW.id AND e.state = 'active' AND e.in_effect && NEW.in_effect
              AND (v.resource_id = r.id OR r.id IN
                   (SELECT s.resource_id FROM registry.offer_version_resources s WHERE s.offer_version_id = v.id)))
     LIMIT 1;
    IF taken IS NOT NULL THEN
        RAISE EXCEPTION '% already holds an active run right to % over %: end it before another begins',
            holder, taken, NEW.in_effect;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

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
        EXECUTE format($f$
            CREATE TRIGGER entitlement_one_run_right
                BEFORE INSERT OR UPDATE ON %I.entitlements
                FOR EACH ROW EXECUTE FUNCTION registry.entitlement_one_run_right()
        $f$, s);
    END LOOP;
END $$;

-- The trigger guards new rows; refuse to deploy over a pair it would have refused.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM registry.entitlements a
          JOIN registry.entitlements b
            ON coalesce(b.holder_user_id, b.holder_family_member_id, b.holder_tenant_id)
             = coalesce(a.holder_user_id, a.holder_family_member_id, a.holder_tenant_id)
           AND b.id > a.id AND b.state = 'active' AND b.in_effect && a.in_effect
          JOIN registry.offer_versions va ON va.id = a.offer_version_id
          JOIN registry.offer_versions vb ON vb.id = b.offer_version_id
          JOIN registry.resources r ON r.name LIKE 'run:%'
           AND (r.id = va.resource_id OR r.id IN (SELECT resource_id FROM registry.offer_version_resources
                                                   WHERE offer_version_id = va.id))
           AND (r.id = vb.resource_id OR r.id IN (SELECT resource_id FROM registry.offer_version_resources
                                                   WHERE offer_version_id = vb.id))
         WHERE a.state = 'active')
    THEN
        RAISE EXCEPTION 'cannot guard run rights: a holder already holds two active run rights to one '
                        'workflow over the same period';
    END IF;
END $$;

COMMIT;
