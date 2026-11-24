-- ABOUTME: The bootstrap root's offers: Solo v1 to tenants, and the platform's offers to itself.
-- ABOUTME: Seeds registry's resources, offer versions and the registry tenant's entitlements, by fixed id.

-- Deploy registry:bootstrap-platform-offers to pg
-- requires: priceops-entitlement-units

BEGIN;

SET client_min_messages = 'warning';

-- Nothing has been sold through Registry, so Solo is written fresh under the
-- terms decided with perigrin; no pricing_plans row is copied. Fixed ids, so
-- the revert removes exactly these rows. Each version is inserted as a draft,
-- given its plan, then published: the database refuses a published version
-- with no plan, and refuses plans added to a published one.

INSERT INTO registry.resources (id, name, kind) VALUES
    ('00000000-0000-0000-0001-000000000001', 'payment processing', 'unbounded'),
    ('00000000-0000-0000-0001-000000000002', 'email sending',      'unbounded');

INSERT INTO registry.offers (id, name) VALUES
    ('00000000-0000-0000-0002-000000000001', 'Solo'),
    ('00000000-0000-0000-0002-000000000002', 'Platform payment processing'),
    ('00000000-0000-0000-0002-000000000003', 'Platform email sending');

-- Solo v1: $0 plus 2.5% of each sale; Tamarou keeps its fee on a refund
-- unless the platform tenant's admin applies the exception.
INSERT INTO registry.offer_versions
    (id, offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap, policies)
VALUES
    ('00000000-0000-0000-0003-000000000001', '00000000-0000-0000-0002-000000000001', 1,
     '00000000-0000-0000-0001-000000000001', 0, 1, 1,
     '{"refund": {"kind": "keep_fee_with_admin_exception"}}');

-- The platform's offers to itself, each its own offer buying one resource and
-- restricted by holder_is_offerer to the platform: not offered to tenants.
-- Payment processing at an explicit 0%, so the platform's own sales send no
-- application fee by the ordinary rule; everything else at a stated $0.
INSERT INTO registry.offer_versions
    (id, offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap,
     policies, conditions)
SELECT v.id::uuid, v.offer_id::uuid, 1, v.resource_id::uuid, 0, 1, 1,
       '{"refund": {"kind": "none"}}', '[{"kind": "holder_is_offerer"}]'
  FROM (VALUES
    ('00000000-0000-0000-0003-000000000002', '00000000-0000-0000-0002-000000000002',
     '00000000-0000-0000-0001-000000000001'),
    ('00000000-0000-0000-0003-000000000003', '00000000-0000-0000-0002-000000000003',
     '00000000-0000-0000-0001-000000000002')
  ) AS v (id, offer_id, resource_id);

INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind, fraction) VALUES
    ('00000000-0000-0000-0003-000000000001', 'revenue_share', 'percentage_of_sales', 0.025),
    ('00000000-0000-0000-0003-000000000002', 'revenue_share', 'percentage_of_sales', 0),
    ('00000000-0000-0000-0003-000000000003', 'one_time',      'one_time',            NULL);

UPDATE registry.offer_versions SET published_at = now()
 WHERE id::text LIKE '00000000-0000-0000-0003-%';

-- The registry tenant holds each of its offers to itself from now on.
INSERT INTO registry.entitlements
    (id, holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
SELECT e.id::uuid, '00000000-0000-0000-0000-000000000000', e.version_id::uuid, e.plan_id,
       tstzrange(now(), NULL, '[)')
  FROM (VALUES
    ('00000000-0000-0000-0004-000000000002', '00000000-0000-0000-0003-000000000002', 'revenue_share'),
    ('00000000-0000-0000-0004-000000000003', '00000000-0000-0000-0003-000000000003', 'one_time')
  ) AS e (id, version_id, plan_id);

COMMIT;
