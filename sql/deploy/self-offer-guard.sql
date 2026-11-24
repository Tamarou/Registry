-- ABOUTME: Only the platform tenant may hold an offer version whose conditions include holder_is_offerer.
-- ABOUTME: Enforced in registry, so no accept or checkout flow can give a tenant or person the platform's self-offers.

-- Deploy registry:self-offer-guard to pg
-- requires: operator-right-entitlement

BEGIN;

SET client_min_messages = 'warning';

-- clone_schema copies this function and trigger into each new tenant schema.
-- There offer versions are the tenant's own offers, and holder_is_offerer
-- would mean the tenant itself, so the copy does nothing: the rule is
-- registry's.
CREATE FUNCTION registry.entitlement_holder_is_offerer() RETURNS trigger AS $t$
BEGIN
    IF TG_TABLE_SCHEMA = 'registry'
       AND NEW.holder_tenant_id IS DISTINCT FROM '00000000-0000-0000-0000-000000000000'
       AND EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = NEW.offer_version_id
                      AND conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RAISE EXCEPTION 'offer version % is the platform''s offer to itself (holder_is_offerer): '
                        'only the platform tenant may hold it', NEW.offer_version_id;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

CREATE TRIGGER entitlement_holder_is_offerer
    BEFORE INSERT OR UPDATE ON registry.entitlements
    FOR EACH ROW EXECUTE FUNCTION registry.entitlement_holder_is_offerer();

-- The trigger guards new rows; refuse to deploy over one it would have refused.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.entitlements e
                 JOIN registry.offer_versions v ON v.id = e.offer_version_id
                WHERE v.conditions @> '[{"kind": "holder_is_offerer"}]'
                  AND e.holder_tenant_id IS DISTINCT FROM '00000000-0000-0000-0000-000000000000') THEN
        RAISE EXCEPTION 'cannot guard the platform''s self-offers: registry.entitlements already '
                        'gives one to a holder other than the platform tenant';
    END IF;
END $$;

COMMIT;
