-- ABOUTME: Publishes Solo v2, whose stored set grants payment processing and the run right to every shipped workflow.
-- ABOUTME: It supersedes the unheld Solo v1 on v1's price, policies and 2.5% share; registry only, as Solo is registry's.

-- Deploy registry:solo-grants-workflow-set to pg
-- requires: entitlement-terms-version

BEGIN;

SET client_min_messages = 'warning';

-- perigrin, 2026-11-26: "Yes it may grant every workflow, that grant should be
-- built into the offer though so a later offer maybe only offers *some*
-- workflows". The grant is this version's stored set (offer_version_resources):
-- nothing computes "every workflow" when a tenant accepts. The list below is
-- every non-draft workflow shipped in workflows/ when this change was written,
-- less Registry::WorkflowDivergence::never_copied. It cannot be read from
-- registry.workflows: a fresh deploy has none until `workflow import` runs.
-- A workflow added later is granted only by a new Solo version that lists it;
-- t/priceops/solo-lists-every-shipped-workflow.t fails until one does.
CREATE TEMPORARY TABLE solo_workflow_set (slug text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO solo_workflow_set (slug) VALUES
    ('__default__'),
    ('admin-dashboard'),
    ('admin-drop-approval'),
    ('admin-transfer-approval'),
    ('attendance-check'),
    ('drop-request-processing'),
    ('entitlement-change'),
    ('entitlement-refund'),
    ('entitlement-stripe-move'),
    ('event-creation'),
    ('in-studio-booking'),
    ('in-studio-class-setup'),
    ('in-studio-day-view'),
    ('in-studio-schedule'),
    ('location-creation'),
    ('location-management'),
    ('offer-publishing'),
    ('outcome-definition-creation'),
    ('parent-drop-request'),
    ('parent-transfer-request'),
    ('platform-fee-refund-exception'),
    ('pricing-plan-creation'),
    ('program-creation'),
    ('program-creation-enhanced'),
    ('program-location-assignment'),
    ('program-setup'),
    ('program-type-management'),
    ('project-creation'),
    ('session-creation'),
    ('summer-camp-registration'),
    ('template-editor'),
    ('tenant-storefront'),
    ('transfer-request-processing'),
    ('user-creation'),
    ('workflow-creation');

-- Superseding is only safe while nobody agreed to v1: refuse naming each holder.
DO $$
DECLARE
    holders text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = '00000000-0000-0000-0003-000000000001'
                      AND published_at IS NOT NULL AND superseded_at IS NULL) THEN
        RAISE EXCEPTION 'cannot supersede Solo v1: it is not Solo''s current version';
    END IF;
    SELECT string_agg(DISTINCT coalesce(t.slug, coalesce(e.holder_user_id, e.holder_family_member_id)::text), ', ')
      INTO holders
      FROM registry.entitlements e LEFT JOIN registry.tenants t ON t.id = e.holder_tenant_id
     WHERE e.offer_version_id = '00000000-0000-0000-0003-000000000001';
    IF holders IS NOT NULL THEN
        RAISE EXCEPTION 'cannot supersede Solo v1: tenants [%] hold it', holders;
    END IF;
    IF EXISTS (SELECT 1 FROM registry.resources r JOIN solo_workflow_set w ON r.name = 'run:' || w.slug
                GROUP BY r.name HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'cannot list the workflow set: a workflow has more than one run resource';
    END IF;
END $$;

-- A run resource that exists is reused by name; a missing one takes an id
-- derived from its slug, so the revert removes exactly the ones made here.
INSERT INTO registry.resources (id, name, kind)
SELECT md5('solo-grants-workflow-set/resource/' || w.slug)::uuid, 'run:' || w.slug, 'unbounded'
  FROM solo_workflow_set w
 WHERE NOT EXISTS (SELECT 1 FROM registry.resources r WHERE r.name = 'run:' || w.slug);

-- v2 as a draft on v1's terms, buying the set instead of v1's one resource.
INSERT INTO registry.offer_versions
    (id, offer_id, version, resource_id, price_cents, currency, units_per_acceptance, per_booking_cap,
     policies, conditions, class_project_id)
SELECT md5('solo-grants-workflow-set/version')::uuid, v.offer_id,
       (SELECT max(version) + 1 FROM registry.offer_versions WHERE offer_id = v.offer_id), NULL,
       v.price_cents, v.currency, v.units_per_acceptance, v.per_booking_cap, v.policies, v.conditions, NULL
  FROM registry.offer_versions v WHERE v.id = '00000000-0000-0000-0003-000000000001';

INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind, fraction)
SELECT md5('solo-grants-workflow-set/version')::uuid, id, kind, fraction
  FROM registry.offer_version_payment_plans WHERE offer_version_id = '00000000-0000-0000-0003-000000000001';

INSERT INTO registry.offer_version_resources (offer_version_id, resource_id)
SELECT md5('solo-grants-workflow-set/version')::uuid, resource_id
  FROM registry.offer_versions WHERE id = '00000000-0000-0000-0003-000000000001'
UNION
SELECT md5('solo-grants-workflow-set/version')::uuid, r.id
  FROM registry.resources r JOIN solo_workflow_set w ON r.name = 'run:' || w.slug;

-- One current version per offer: v1 steps down before v2 is published.
UPDATE registry.offer_versions SET superseded_at = now() WHERE id = '00000000-0000-0000-0003-000000000001';
UPDATE registry.offer_versions SET published_at = now() WHERE id = md5('solo-grants-workflow-set/version')::uuid;

COMMIT;
