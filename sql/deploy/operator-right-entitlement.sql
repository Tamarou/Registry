-- ABOUTME: The operator right becomes an entitlement: its own $0 one-time offer from the platform to itself.
-- ABOUTME: Moves the interim table's seeded row into registry's entitlement and drops the interim table.

-- Deploy registry:operator-right-entitlement to pg
-- requires: bootstrap-platform-offers
-- requires: operator-right

BEGIN;

SET client_min_messages = 'warning';

-- The interim table only ever held the platform's operator right; anything
-- else in it would be lost by the drop, so refuse rather than lose it.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.tenant_resources
                WHERE (tenant_id, resource)
                      <> ('00000000-0000-0000-0000-000000000000', 'operator')) THEN
        RAISE EXCEPTION 'cannot move the operator right: registry.tenant_resources holds '
                        'a row other than the platform''s operator right';
    END IF;
END $$;

-- Fixed ids in their own family (0000-0001-...), apart from the bootstrap's,
-- so each change's revert and verify see only its own rows.
INSERT INTO registry.resources (id, name, kind)
VALUES ('00000000-0000-0001-0001-000000000001', 'operator', 'unbounded');

INSERT INTO registry.offers (id, name)
VALUES ('00000000-0000-0001-0002-000000000001', 'Platform operator right');

-- Its own offer version buying the one resource, restricted to the platform,
-- with an explicit one-time $0 plan; drafted, given its plan, then published.
INSERT INTO registry.offer_versions
    (id, offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap,
     policies, conditions)
VALUES ('00000000-0000-0001-0003-000000000001', '00000000-0000-0001-0002-000000000001', 1,
        '00000000-0000-0001-0001-000000000001', 0, 1, 1,
        '{"refund": {"kind": "none"}}', '[{"kind": "holder_is_offerer"}]');

INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind)
VALUES ('00000000-0000-0001-0003-000000000001', 'one_time', 'one_time');

UPDATE registry.offer_versions SET published_at = now()
 WHERE id = '00000000-0000-0001-0003-000000000001';

-- The seeded row, moved: the platform holds the right from now on if, and
-- only if, the interim table said it did.
INSERT INTO registry.entitlements
    (id, holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
SELECT '00000000-0000-0001-0004-000000000001', tenant_id,
       '00000000-0000-0001-0003-000000000001', 'one_time', tstzrange(now(), NULL, '[)')
  FROM registry.tenant_resources;

-- One source. Tenant schemas cloned since operator-right keep their empty
-- copies, as its own revert leaves them: nothing reads those, and a revert
-- could not tell which schemas had one.
DROP TABLE registry.tenant_resources;

COMMIT;
