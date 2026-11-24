-- ABOUTME: Restore tenants.platform_pricing_plan_id and its rate trigger, and the payments plan stamp, in every schema.
-- ABOUTME: Tenants holding Solo are relinked to the launch plan; the backfilled entitlements stay, as the old code ignores them.

-- Revert registry:platform-entitlement-replaces-plan-link from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
    commented boolean;
    idx       name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        -- clone_schema copied the column's comment and index into some tenant
        -- schemas and not others, and named the index its own way; the
        -- replacement has them where, and as, the old one did.
        SELECT i.relname INTO idx
          FROM pg_index x
          JOIN pg_class i ON i.oid = x.indexrelid
          JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = ANY (x.indkey)
         WHERE x.indrelid = format('%I.payments', s)::regclass AND a.attname = 'platform_offer_version_id';
        SELECT col_description(a.attrelid, a.attnum) IS NOT NULL INTO commented
          FROM pg_attribute a
         WHERE a.attrelid = format('%I.payments', s)::regclass AND a.attname = 'platform_offer_version_id';
        EXECUTE format('ALTER TABLE %I.payments
            DROP COLUMN platform_offer_version_id,
            DROP COLUMN platform_payment_plan_id,
            ADD COLUMN platform_pricing_plan_id uuid', s);
        IF idx IS NOT NULL THEN
            EXECUTE format('CREATE INDEX %I ON %I.payments (platform_pricing_plan_id)
                             WHERE platform_fee_cents IS NOT NULL', idx, s);
        END IF;
        CONTINUE WHEN NOT commented;
        EXECUTE format($c$COMMENT ON COLUMN %I.payments.platform_pricing_plan_id IS
            'The pricing_plans row (a specific version) the fee above was charged under, copied from '
            'tenants.platform_pricing_plan_id at settlement. Deliberately not a foreign key: a plan '
            'version may be retired, and the charge still happened.'$c$, s);
    END LOOP;
END $$;

ALTER TABLE registry.tenants
    ADD COLUMN platform_pricing_plan_id uuid REFERENCES registry.pricing_plans (id);

UPDATE registry.tenants t
   SET platform_pricing_plan_id = (SELECT id FROM registry.pricing_plans
                                    WHERE metadata->>'launch_rate' = 'true' AND superseded_at IS NULL)
 WHERE t.slug <> 'registry'
   AND EXISTS (SELECT 1 FROM registry.entitlements e
                WHERE e.holder_tenant_id = t.id AND e.state = 'active'
                  AND e.offer_version_id = '00000000-0000-0000-0003-000000000001');

CREATE FUNCTION registry.tenant_plan_has_rate() RETURNS trigger AS $t$
BEGIN
    IF NEW.platform_pricing_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM registry.pricing_plans
         WHERE id = NEW.platform_pricing_plan_id
           AND pricing_configuration->>'percentage' IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'tenant % cannot be linked to pricing plan %: it has no rate',
            NEW.slug, NEW.platform_pricing_plan_id;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

CREATE TRIGGER tenants_plan_has_rate
    BEFORE INSERT OR UPDATE OF platform_pricing_plan_id ON registry.tenants
    FOR EACH ROW EXECUTE FUNCTION registry.tenant_plan_has_rate();

COMMIT;
