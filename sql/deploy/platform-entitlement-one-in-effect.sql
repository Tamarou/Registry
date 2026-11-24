-- ABOUTME: A tenant holds at most one active platform entitlement to payment processing at any moment.
-- ABOUTME: Enforced in registry, so the fee resolver reads one set of terms and never picks between two.

-- Deploy registry:platform-entitlement-one-in-effect to pg
-- requires: self-offer-guard

BEGIN;

SET client_min_messages = 'warning';

-- One offer's phases are already exclusive (priceops-entitlement-one-phase);
-- this covers two different offers for the same resource. A trigger rather
-- than an EXCLUDE, which cannot join to the version's resource; the advisory
-- lock per holder makes two concurrent grants take turns, so the second sees
-- the first. clone_schema copies it into tenant schemas, where a holder is
-- never a tenant, so the copy does nothing: the rule is registry's.
CREATE FUNCTION registry.entitlement_one_platform_term() RETURNS trigger AS $t$
BEGIN
    IF TG_TABLE_SCHEMA <> 'registry' OR NEW.holder_tenant_id IS NULL OR NEW.state <> 'active'
       OR NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                        JOIN registry.resources r ON r.id = v.resource_id
                       WHERE v.id = NEW.offer_version_id AND r.name = 'payment processing')
    THEN
        RETURN NEW;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('platform_entitlement:' || NEW.holder_tenant_id, 0));
    IF EXISTS (SELECT 1 FROM registry.entitlements e
                 JOIN registry.offer_versions v ON v.id = e.offer_version_id
                 JOIN registry.resources r ON r.id = v.resource_id
                WHERE e.holder_tenant_id = NEW.holder_tenant_id AND e.id <> NEW.id
                  AND e.state = 'active' AND r.name = 'payment processing'
                  AND e.in_effect && NEW.in_effect)
    THEN
        RAISE EXCEPTION 'tenant % already holds an active platform entitlement to payment processing '
                        'over %: end it before another begins', NEW.holder_tenant_id, NEW.in_effect;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

CREATE TRIGGER entitlement_one_platform_term
    BEFORE INSERT OR UPDATE ON registry.entitlements
    FOR EACH ROW EXECUTE FUNCTION registry.entitlement_one_platform_term();

-- The trigger guards new rows; refuse to deploy over a pair it would have refused.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.entitlements a
                 JOIN registry.entitlements b
                   ON b.holder_tenant_id = a.holder_tenant_id AND b.id > a.id
                  AND b.in_effect && a.in_effect AND b.state = 'active'
                 JOIN registry.offer_versions va ON va.id = a.offer_version_id
                 JOIN registry.offer_versions vb ON vb.id = b.offer_version_id
                 JOIN registry.resources r ON r.id = va.resource_id AND r.id = vb.resource_id
                WHERE a.state = 'active' AND r.name = 'payment processing') THEN
        RAISE EXCEPTION 'cannot guard platform entitlements: a tenant already holds two active '
                        'platform entitlements to payment processing over the same period';
    END IF;
END $$;

COMMIT;
