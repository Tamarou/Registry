-- ABOUTME: Registry always keeps a current published platform offer to tenants, so signup never has none to grant.
-- ABOUTME: Checked at commit, so publishing a new version (supersede, then append) in one transaction still passes.

-- Deploy registry:platform-offer-to-tenants-guard to pg
-- requires: offer-publishing-adds-expiry-policy

BEGIN;

SET client_min_messages = 'warning';

-- "A platform offer to tenants" is TenantPayment::_platform_offer_to_tenants's
-- predicate: a current published payment-processing version with a
-- percentage-of-sales plan and without holder_is_offerer. Published rows are
-- immutable and never deleted, so retiring one is the only way to lose one.
-- Only zero is refused; more than one is signup's concern. The advisory lock
-- makes two commits retiring different offers take turns, so the second sees
-- the first. clone_schema copies this into tenant schemas, where offers are
-- the tenant's own, so the copy does nothing: the rule is registry's.
CREATE FUNCTION registry.offer_versions_keep_platform_offer() RETURNS trigger AS $t$
BEGIN
    IF TG_TABLE_SCHEMA <> 'registry'
       OR NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                        JOIN registry.resources r ON r.id = v.resource_id
                        JOIN registry.offer_version_payment_plans p
                          ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                       WHERE v.id = OLD.id AND r.name = 'payment processing'
                         AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RETURN NULL;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('platform_offer_to_tenants', 0));
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                     JOIN registry.resources r ON r.id = v.resource_id
                     JOIN registry.offer_version_payment_plans p
                       ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                    WHERE r.name = 'payment processing'
                      AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
                      AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RAISE EXCEPTION 'retiring offer version % leaves no current published platform offer to tenants: '
                        'signup could grant none. Publish one on payment processing with a '
                        'percentage-of-sales plan first', OLD.id;
    END IF;
    RETURN NULL;
END;
$t$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER offer_versions_keep_platform_offer
    AFTER UPDATE OF superseded_at ON registry.offer_versions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL)
    EXECUTE FUNCTION registry.offer_versions_keep_platform_offer();

-- The trigger guards retirements; refuse to deploy over a state it would have refused.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                     JOIN registry.resources r ON r.id = v.resource_id
                     JOIN registry.offer_version_payment_plans p
                       ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                    WHERE r.name = 'payment processing'
                      AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
                      AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]') THEN
        RAISE EXCEPTION 'cannot guard the platform offer to tenants: registry has no current '
                        'published one to keep';
    END IF;
END $$;

COMMIT;
