-- ABOUTME: Registry's resource a current platform offer to tenants is for keeps its name, "payment processing".
-- ABOUTME: Signup and the platform-offer guard find that offer by the name, so a rename would retire it unseen.

-- Deploy registry:platform-offer-resource-keeps-name to pg
-- requires: platform-offer-to-tenants-guard

BEGIN;

SET client_min_messages = 'warning';

-- The same predicate as offer_versions_keep_platform_offer, on the renamed row.
-- Deleting it is already refused by offer_versions' foreign key. clone_schema
-- copies this into tenant schemas, where resources are the tenant's own, so
-- the copy does nothing.
CREATE FUNCTION registry.resources_keep_platform_offer_name() RETURNS trigger AS $t$
BEGIN
    IF TG_TABLE_SCHEMA = 'registry'
       AND EXISTS (SELECT 1 FROM registry.offer_versions v
                     JOIN registry.offer_version_payment_plans p
                       ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                    WHERE v.resource_id = OLD.id
                      AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
                      AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RAISE EXCEPTION 'resource % is what the current platform offer to tenants is for: signup finds it '
                        'by the name payment processing, so it keeps that name', OLD.id;
    END IF;
    RETURN NULL;
END;
$t$ LANGUAGE plpgsql;

CREATE TRIGGER resources_keep_platform_offer_name
    AFTER UPDATE OF name ON registry.resources
    FOR EACH ROW
    WHEN (OLD.name = 'payment processing' AND NEW.name IS DISTINCT FROM OLD.name)
    EXECUTE FUNCTION registry.resources_keep_platform_offer_name();

COMMIT;
