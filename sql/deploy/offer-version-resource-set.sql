-- ABOUTME: An offer version may buy a set of resources (ADR 004 ruling (a)), listed in offer_version_resources.
-- ABOUTME: In registry and every tenant schema; the set is frozen at publish, and registry's guards read it.

-- Deploy registry:offer-version-resource-set to pg
-- requires: attendance-check-drops-schedule-next

BEGIN;

SET client_min_messages = 'warning';

-- A version buys exactly one of: its resource_id, its class_project_id, or
-- the set listed in offer_version_resources. Single-resource versions are
-- unchanged; a set version has neither column and at least one member.

-- Members change only while the version is a draft, and only on a version
-- that names neither a resource nor a class. FOR SHARE, so a concurrent
-- publish waits for this change, or this one sees it.
CREATE FUNCTION registry.offer_version_resource_set_guard() RETURNS trigger AS $t$
DECLARE
    old_version uuid;
    new_version uuid;
    v record;
BEGIN
    IF TG_OP <> 'INSERT' THEN old_version := OLD.offer_version_id; END IF;
    IF TG_OP <> 'DELETE' THEN new_version := NEW.offer_version_id; END IF;
    FOR v IN EXECUTE format(
        'SELECT id, offer_id, version, published_at, resource_id, class_project_id
           FROM %I.offer_versions WHERE id IN ($1, $2) FOR SHARE', TG_TABLE_SCHEMA)
        USING old_version, new_version
    LOOP
        IF v.published_at IS NOT NULL THEN
            RAISE EXCEPTION
                'offer % version % is published: the resources it buys cannot be '
                'added, changed or removed. Publish a new version instead.',
                v.offer_id, v.version;
        END IF;
        IF v.id = new_version AND num_nonnulls(v.resource_id, v.class_project_id) > 0 THEN
            RAISE EXCEPTION
                'offer % version % buys one resource or a class: it cannot also buy a set',
                v.offer_id, v.version;
        END IF;
    END LOOP;
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$t$ LANGUAGE plpgsql;

-- At publish (checked at commit, so a draft's members may follow its row) a
-- version buys exactly one thing: absence is not zero.
CREATE FUNCTION registry.offer_version_requires_purchase() RETURNS trigger AS $t$
DECLARE
    has_set boolean;
BEGIN
    IF NEW.published_at IS NULL THEN RETURN NULL; END IF;
    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM %I.offer_version_resources WHERE offer_version_id = $1)',
        TG_TABLE_SCHEMA) INTO has_set USING NEW.id;
    IF num_nonnulls(NEW.resource_id, NEW.class_project_id) + has_set::int = 0 THEN
        RAISE EXCEPTION 'offer % version % buys nothing and cannot be published',
            NEW.offer_id, NEW.version;
    END IF;
    IF num_nonnulls(NEW.resource_id, NEW.class_project_id) + has_set::int > 1 THEN
        RAISE EXCEPTION 'offer % version % buys a set and a resource or class: it may buy only one',
            NEW.offer_id, NEW.version;
    END IF;
    RETURN NULL;
END;
$t$ LANGUAGE plpgsql;

-- registry's guards read what a version buys through the set too. Each copy
-- clone_schema gave a tenant does nothing there (the rules are registry's),
-- so only registry's own definitions change.
CREATE OR REPLACE FUNCTION registry.entitlement_one_platform_term() RETURNS trigger AS $t$
BEGIN
    IF TG_TABLE_SCHEMA <> 'registry' OR NEW.holder_tenant_id IS NULL OR NEW.state <> 'active'
       OR NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                        JOIN registry.resources r ON r.id = v.resource_id OR r.id IN
                             (SELECT s.resource_id FROM registry.offer_version_resources s
                               WHERE s.offer_version_id = v.id)
                       WHERE v.id = NEW.offer_version_id AND r.name = 'payment processing')
    THEN
        RETURN NEW;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('platform_entitlement:' || NEW.holder_tenant_id, 0));
    IF EXISTS (SELECT 1 FROM registry.entitlements e
                 JOIN registry.offer_versions v ON v.id = e.offer_version_id
                 JOIN registry.resources r ON r.id = v.resource_id OR r.id IN
                      (SELECT s.resource_id FROM registry.offer_version_resources s
                        WHERE s.offer_version_id = v.id)
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
                        JOIN registry.resources r ON r.id = v.resource_id OR r.id IN
                             (SELECT s.resource_id FROM registry.offer_version_resources s
                               WHERE s.offer_version_id = v.id)
                        JOIN registry.offer_version_payment_plans p
                          ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
                       WHERE v.id = OLD.id AND r.name = 'payment processing'
                         AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]')
    THEN
        RETURN NULL;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('platform_offer_to_tenants', 0));
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions v
                     JOIN registry.resources r ON r.id = v.resource_id OR r.id IN
                          (SELECT s.resource_id FROM registry.offer_version_resources s
                            WHERE s.offer_version_id = v.id)
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
                    WHERE (v.resource_id = OLD.id OR OLD.id IN
                           (SELECT s.resource_id FROM registry.offer_version_resources s
                             WHERE s.offer_version_id = v.id))
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
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.offer_versions', s)) IS NULL;

        EXECUTE format($f$
            CREATE TABLE %1$I.offer_version_resources (
                offer_version_id uuid NOT NULL
                    REFERENCES %1$I.offer_versions (id) ON DELETE CASCADE,
                resource_id uuid NOT NULL REFERENCES %1$I.resources (id),
                PRIMARY KEY (offer_version_id, resource_id)
            )
        $f$, s);
        EXECUTE format($f$
            CREATE TRIGGER offer_version_resources_guard
                BEFORE INSERT OR UPDATE OR DELETE ON %I.offer_version_resources
                FOR EACH ROW EXECUTE FUNCTION registry.offer_version_resource_set_guard()
        $f$, s);
        EXECUTE format($f$
            CREATE CONSTRAINT TRIGGER offer_versions_require_purchase
                AFTER INSERT OR UPDATE OF published_at ON %I.offer_versions
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION registry.offer_version_requires_purchase()
        $f$, s);
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_versions
                DROP CONSTRAINT offer_versions_buys_resource_or_class,
                ADD CONSTRAINT offer_versions_buys_resource_or_class
                    CHECK (num_nonnulls(resource_id, class_project_id) <= 1)
        $f$, s);
    END LOOP;
END $$;

COMMIT;
