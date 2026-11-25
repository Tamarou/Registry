-- ABOUTME: Reverts offer-version-resource-set: a version buys one resource or a class again, in every schema.
-- ABOUTME: Refuses while any version lists a set, since restoring the old check would orphan what it sold.

-- Revert registry:offer-version-resource-set from pg

BEGIN;

SET client_min_messages = 'warning';

-- registry's guards first: the tenant copies below are rebuilt from them.

CREATE OR REPLACE FUNCTION registry.entitlement_one_platform_term() RETURNS trigger AS $t$
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

CREATE OR REPLACE FUNCTION registry.offer_versions_keep_platform_offer() RETURNS trigger AS $t$
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

CREATE OR REPLACE FUNCTION registry.resources_keep_platform_offer_name() RETURNS trigger AS $t$
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


DO $$
DECLARE
    s name;
    n bigint;
    draft uuid;
    fn text;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.offer_version_resources', s)) IS NULL;
        EXECUTE format('SELECT count(*) FROM %I.offer_version_resources', s) INTO n;
        IF n > 0 THEN
            RAISE EXCEPTION 'cannot revert offer-version-resource-set: schema % has offer versions '
                            'that buy a set of resources', s;
        END IF;
        -- An empty set draft would fail the restored check with no name; say which.
        EXECUTE format('SELECT id FROM %I.offer_versions
                         WHERE resource_id IS NULL AND class_project_id IS NULL LIMIT 1', s) INTO draft;
        IF draft IS NOT NULL THEN
            RAISE EXCEPTION 'cannot revert offer-version-resource-set: offer version % in schema % '
                            'buys neither a resource nor a class (an empty set draft): delete it or '
                            'give it a resource first', draft, s;
        END IF;

        EXECUTE format('DROP TABLE %I.offer_version_resources', s);
        EXECUTE format('DROP TRIGGER offer_versions_require_purchase ON %I.offer_versions', s);
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_versions
                DROP CONSTRAINT offer_versions_buys_resource_or_class,
                ADD CONSTRAINT offer_versions_buys_resource_or_class
                    CHECK (num_nonnulls(resource_id, class_project_id) = 1)
        $f$, s);
        -- A tenant cloned since deploy carries its own copies of the new functions.
        IF s != 'registry' THEN
            EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_version_resource_set_guard()', s);
            EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_version_requires_purchase()', s);
            EXECUTE format('DROP FUNCTION IF EXISTS %I.offer_version_resources_no_truncate()', s);
            -- Its copies of the guards name offer_version_resources unqualified,
            -- and PL/pgSQL plans the whole IF, so each is rebuilt from registry's
            -- restored body the way clone_schema copies it.
            FOREACH fn IN ARRAY ARRAY['entitlement_one_platform_term', 'offer_versions_keep_platform_offer',
                                      'resources_keep_platform_offer_name']
            LOOP
                CONTINUE WHEN to_regprocedure(format('%I.%I()', s, fn)) IS NULL;
                EXECUTE replace(
                    replace(pg_get_functiondef(format('registry.%I()', fn)::regprocedure),
                            format('FUNCTION registry.%s()', fn), format('FUNCTION %I.%I()', s, fn)),
                    'registry.', '');
            END LOOP;
        END IF;
    END LOOP;
END $$;

DROP FUNCTION registry.offer_version_resource_set_guard();
DROP FUNCTION registry.offer_version_requires_purchase();
DROP FUNCTION registry.offer_version_resources_no_truncate();

COMMIT;
