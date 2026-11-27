-- ABOUTME: Publishes Solo v3: v2's price, fee, policies and set, plus run rights to the four session workflows.
-- ABOUTME: Each active v2 holder moves onto v3 at the same instant on the same plan; refuses if v3's terms differ from v2's.

-- Deploy registry:solo-grants-session-workflows to pg
-- requires: template-editor-admin-only
-- (logically it needs solo-grants-workflow-set, which publishes Solo v2)

BEGIN;

SET client_min_messages = 'warning';

-- perigrin, 2026-11-27 (plan contradiction A): a stamped entitlement never
-- changes, so v2 holders could never run these workflows. They move to v3,
-- which differs from v2 only by the four run rights below.
CREATE TEMPORARY TABLE solo_session_workflows (slug text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO solo_session_workflows (slug) VALUES
    ('entitlement-decision'),
    ('makeup-booking'),
    ('session-checkout'),
    ('session-setup');

DO $$
DECLARE
    paid text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = md5('solo-grants-workflow-set/version')::uuid
                      AND published_at IS NOT NULL AND superseded_at IS NULL) THEN
        RAISE EXCEPTION 'cannot supersede Solo v2: it is not Solo''s current version';
    END IF;
    -- The payment link is set only at insert, so a moved holder would lose it.
    SELECT string_agg(DISTINCT coalesce(t.slug, coalesce(e.holder_user_id, e.holder_family_member_id)::text), ', ')
      INTO paid
      FROM registry.entitlements e LEFT JOIN registry.tenants t ON t.id = e.holder_tenant_id
     WHERE e.offer_version_id = md5('solo-grants-workflow-set/version')::uuid
       AND e.state = 'active' AND e.payment_id IS NOT NULL;
    IF paid IS NOT NULL THEN
        RAISE EXCEPTION 'cannot move Solo v2 holders [%] to v3: their entitlements link a payment', paid;
    END IF;
    IF EXISTS (SELECT 1 FROM registry.resources r JOIN solo_session_workflows w ON r.name = 'run:' || w.slug
                GROUP BY r.name HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'cannot list the session workflows: a workflow has more than one run resource';
    END IF;
END $$;

-- Reused by name; a missing one takes an id derived from its slug, so the
-- revert removes exactly the ones made here.
INSERT INTO registry.resources (id, name, kind)
SELECT md5('solo-grants-session-workflows/resource/' || w.slug)::uuid, 'run:' || w.slug, 'unbounded'
  FROM solo_session_workflows w
 WHERE NOT EXISTS (SELECT 1 FROM registry.resources r WHERE r.name = 'run:' || w.slug);

-- v3 as a draft on v2's terms.
INSERT INTO registry.offer_versions
    (id, offer_id, version, resource_id, price_cents, currency, units_per_acceptance, per_booking_cap,
     policies, conditions, class_project_id)
SELECT md5('solo-grants-session-workflows/version')::uuid, v.offer_id,
       (SELECT max(version) + 1 FROM registry.offer_versions WHERE offer_id = v.offer_id), v.resource_id,
       v.price_cents, v.currency, v.units_per_acceptance, v.per_booking_cap, v.policies, v.conditions,
       v.class_project_id
  FROM registry.offer_versions v WHERE v.id = md5('solo-grants-workflow-set/version')::uuid;

INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind, fraction)
SELECT md5('solo-grants-session-workflows/version')::uuid, id, kind, fraction
  FROM registry.offer_version_payment_plans WHERE offer_version_id = md5('solo-grants-workflow-set/version')::uuid;

INSERT INTO registry.offer_version_resources (offer_version_id, resource_id)
SELECT md5('solo-grants-session-workflows/version')::uuid, resource_id
  FROM registry.offer_version_resources WHERE offer_version_id = md5('solo-grants-workflow-set/version')::uuid
UNION
SELECT md5('solo-grants-session-workflows/version')::uuid, r.id
  FROM registry.resources r JOIN solo_session_workflows w ON r.name = 'run:' || w.slug;

-- Holders move without agreeing again, so only onto terms they already agreed to.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM registry.offer_versions v2, registry.offer_versions v3
         WHERE v2.id = md5('solo-grants-workflow-set/version')::uuid
           AND v3.id = md5('solo-grants-session-workflows/version')::uuid
           AND (v2.price_cents, v2.currency, v2.policies) IS DISTINCT FROM (v3.price_cents, v3.currency, v3.policies))
    OR EXISTS (
        (SELECT id, kind, fraction FROM registry.offer_version_payment_plans
          WHERE offer_version_id = md5('solo-grants-workflow-set/version')::uuid
         EXCEPT
         SELECT id, kind, fraction FROM registry.offer_version_payment_plans
          WHERE offer_version_id = md5('solo-grants-session-workflows/version')::uuid)
        UNION ALL
        (SELECT id, kind, fraction FROM registry.offer_version_payment_plans
          WHERE offer_version_id = md5('solo-grants-session-workflows/version')::uuid
         EXCEPT
         SELECT id, kind, fraction FROM registry.offer_version_payment_plans
          WHERE offer_version_id = md5('solo-grants-workflow-set/version')::uuid))
    THEN
        RAISE EXCEPTION 'Solo v3 must keep v2''s price, fee and policies';
    END IF;
END $$;

-- One current version per offer: v2 steps down before v3 is published.
UPDATE registry.offer_versions SET superseded_at = now() WHERE id = md5('solo-grants-workflow-set/version')::uuid;
UPDATE registry.offer_versions SET published_at = now() WHERE id = md5('solo-grants-session-workflows/version')::uuid;

-- Each active v2 holder: v2 ends now and v3 begins at that instant on the same
-- plan, payer and terms version (one not yet begun keeps its own start and end).
CREATE TEMPORARY TABLE solo_v2_holders ON COMMIT DROP AS
SELECT id, holder_tenant_id, holder_user_id, holder_family_member_id, payer_user_id, payment_plan_id,
       terms_version, tstzrange(greatest(lower(in_effect), now()), upper(in_effect), '[)') AS v3_in_effect
  FROM registry.entitlements
 WHERE offer_version_id = md5('solo-grants-workflow-set/version')::uuid AND state = 'active'
   AND (upper_inf(in_effect) OR upper(in_effect) > now());

UPDATE registry.entitlements e
   SET state = 'expired', ended_reason = 'superseded by Solo v3', ended_at = now(),
       in_effect = e.in_effect * tstzrange(NULL, now())
  FROM solo_v2_holders h WHERE e.id = h.id;

INSERT INTO registry.entitlements
    (holder_tenant_id, holder_user_id, holder_family_member_id, payer_user_id, offer_version_id, payment_plan_id,
     in_effect, terms_version)
SELECT holder_tenant_id, holder_user_id, holder_family_member_id, payer_user_id,
       md5('solo-grants-session-workflows/version')::uuid, payment_plan_id, v3_in_effect, terms_version
  FROM solo_v2_holders;

COMMIT;
