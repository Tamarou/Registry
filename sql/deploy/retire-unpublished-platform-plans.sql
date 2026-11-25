-- ABOUTME: Retire the migration-authored platform plans for tenants other than Solo: Studio, Empire, Registry Plus and Standard.
-- ABOUTME: Unreferenced rows are deleted, referenced ones superseded; all are kept in public.retired_platform_plans for the revert.

-- Deploy registry:retire-unpublished-platform-plans to pg
-- requires: entitlement-refunds-per-entitlement

BEGIN;

SET client_min_messages = 'warning';

-- On day one the platform sells exactly one offer, Solo, as a published offer
-- version; signup reads those (PlatformTerms::platform_offers_to_tenants), not
-- pricing_plans. Solo's own plan row stays (RevenueShare reads its launch_rate).
-- Rows are chosen by what the changes that made or retired them recorded, never
-- by name: seed-tier-pricing-options stamped Studio and Empire;
-- retire-registry-plus-plan retired the tenant hybrid (Registry Plus);
-- suspend-rateless-tenant-plans pulled the rateless one (Registry Standard).
-- Free went in remove-free-platform-plan. Registry only: a tenant's own plans
-- live in its schema. Outside registry, so clone_schema does not copy it.
CREATE TABLE public.retired_platform_plans AS
SELECT * FROM registry.pricing_plans
 WHERE plan_scope = 'tenant' AND superseded_at IS NULL
   AND (metadata->>'created_by_migration' = 'seed-tier-pricing-options'
        OR plan_type = 'hybrid'
        OR pricing_configuration->>'percentage' IS NULL);

-- A row a payment, sale or entitlement names is kept so its stamp resolves,
-- and superseded so it is not current. The columns are remove-free-platform-
-- plan's: pricing_plans ids live in columns with no foreign key, in registry
-- and every tenant schema.
CREATE TEMP TABLE referenced_platform_plans (id uuid PRIMARY KEY) ON COMMIT DROP;

DO $$
DECLARE
    c record;
BEGIN
    FOR c IN
        SELECT table_schema, table_name, column_name
          FROM information_schema.columns
         WHERE (table_name, column_name) IN (('payments', 'platform_offer_version_id'),
                                             ('payments', 'offer_version_id'),
                                             ('payment_items', 'pricing_plan_id'),
                                             ('offer_versions', 'id'),
                                             ('entitlements', 'offer_version_id'))
           AND table_schema IN (SELECT 'registry' UNION ALL SELECT slug FROM registry.tenants)
    LOOP
        EXECUTE format('INSERT INTO referenced_platform_plans
                        SELECT DISTINCT %3$I FROM %1$I.%2$I
                         WHERE %3$I IN (SELECT id FROM public.retired_platform_plans)
                        ON CONFLICT DO NOTHING',
                       c.table_schema, c.table_name, c.column_name);
    END LOOP;
END $$;

UPDATE registry.pricing_plans SET superseded_at = now()
 WHERE id IN (SELECT id FROM referenced_platform_plans);

DELETE FROM registry.pricing_plans
 WHERE id IN (SELECT id FROM public.retired_platform_plans)
   AND id NOT IN (SELECT id FROM referenced_platform_plans);

COMMIT;
