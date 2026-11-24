-- ABOUTME: A tenant's platform fee comes from its platform entitlement: Solo-linked tenants get Solo v1, the plan link goes.
-- ABOUTME: Payments stamp the platform offer version and payment plan the fee was taken under, in every schema.

-- Deploy registry:platform-entitlement-replaces-plan-link to pg
-- requires: platform-entitlement-one-in-effect

BEGIN;

SET client_min_messages = 'warning';

-- Backfill, drop and reader switch land together, so the link and the
-- entitlement are never both in force. One transaction: a refusal below
-- leaves every tenant, link and entitlement as it was.

-- A link outside the Solo family has no published offer to map to. Refuse
-- rather than guess: which offer that tenant accepted is a person's call.
-- The Solo family is the one carrying the launch_rate marker (a one-time
-- data migration may read it). registry is skipped: it holds the 0%
-- self-offer and takes no share of its own sales, whatever its row names.
DO $$
DECLARE
    bad record;
BEGIN
    SELECT t.slug, p.id, p.plan_name INTO bad
      FROM registry.tenants t
      JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
     WHERE t.slug <> 'registry'
       AND p.plan_family_id NOT IN (SELECT plan_family_id FROM registry.pricing_plans
                                     WHERE metadata->>'launch_rate' = 'true')
     ORDER BY t.slug
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'tenant % is linked to platform plan % (%), which is not a Solo version: '
                        'no published offer matches it. Ask which offer it accepted before deploying.',
                        bad.slug, bad.id, bad.plan_name;
    END IF;
END $$;

-- Tenants provisioned since signup grants entitlements already hold one.
INSERT INTO registry.entitlements (holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
SELECT t.id, '00000000-0000-0000-0003-000000000001', 'revenue_share', tstzrange(now(), NULL, '[)')
  FROM registry.tenants t
 WHERE t.platform_pricing_plan_id IS NOT NULL
   AND t.slug <> 'registry'
   AND NOT EXISTS (
        SELECT 1 FROM registry.entitlements e
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE e.holder_tenant_id = t.id AND r.name = 'payment processing'
           AND e.state = 'active' AND e.in_effect && tstzrange(now(), NULL, '[)'));

DROP TRIGGER tenants_plan_has_rate ON registry.tenants;
DROP FUNCTION registry.tenant_plan_has_rate();
ALTER TABLE registry.tenants DROP COLUMN platform_pricing_plan_id;

-- The stamp names the offer version and its payment plan rather than a
-- pricing plan. A stamp held before this change named a pricing_plans row,
-- not a version, so it is dropped rather than relabelled; such a payment
-- reads as not recorded.
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
         WHERE x.indrelid = format('%I.payments', s)::regclass AND a.attname = 'platform_pricing_plan_id';
        SELECT col_description(a.attrelid, a.attnum) IS NOT NULL INTO commented
          FROM pg_attribute a
         WHERE a.attrelid = format('%I.payments', s)::regclass AND a.attname = 'platform_pricing_plan_id';
        EXECUTE format('ALTER TABLE %I.payments
            DROP COLUMN platform_pricing_plan_id,
            ADD COLUMN platform_offer_version_id uuid,
            ADD COLUMN platform_payment_plan_id text', s);
        IF idx IS NOT NULL THEN
            EXECUTE format('CREATE INDEX %I ON %I.payments (platform_offer_version_id)
                             WHERE platform_fee_cents IS NOT NULL', idx, s);
        END IF;
        CONTINUE WHEN NOT commented;
        EXECUTE format($c$COMMENT ON COLUMN %I.payments.platform_offer_version_id IS
            'The platform offer version (registry.offer_versions) the fee above was taken under, '
            'from the tenant''s platform entitlement when the payment was created. Not a foreign key: '
            'offer versions live in registry, and a superseded version still priced the charge.'$c$, s);
        EXECUTE format($c$COMMENT ON COLUMN %I.payments.platform_payment_plan_id IS
            'Which of that version''s payment plans the tenant accepted; with the version, the whole stamp.'$c$, s);
    END LOOP;
END $$;

COMMIT;
