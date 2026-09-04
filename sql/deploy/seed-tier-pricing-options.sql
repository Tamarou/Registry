-- ABOUTME: Put the Solo/Studio/Empire tier model into the plans the signup page renders.
-- ABOUTME: Solo is buyable; Studio and Empire are visible anchors, refused at selection.

-- Deploy registry:seed-tier-pricing-options to pg
-- requires: set-launch-revenue-share-rate

BEGIN;

SET client_min_messages = 'warning';

-- The pricing page has been able to render a tier ladder since it was written --
-- display_order, a coming-soon badge, a featured card -- and no seeded plan has
-- ever carried the keys it reads. Signup showed a single option named "Registry
-- Revenue Share", which is an internal name, at $0/mo.
--
-- Solo is the plan tenants already link to, renamed. Its rate is the launch rate
-- set by the previous change, and its FK links are untouched, so nothing has to
-- be repointed.
UPDATE registry.pricing_plans
   SET plan_name = 'Solo',
       metadata  = metadata || '{"display_order": 1, "featured": true}'::jsonb,
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'launch_rate' = 'true';

-- Studio and Empire exist to be looked at. They anchor Solo's price and show
-- that the platform has somewhere to grow to; neither is purchasable, and
-- PricingPlanSelection refuses them at selection rather than trusting the
-- disabled attribute on their radio button.
--
-- They need an ACTIVE relationship regardless, because prepare_pricing_data
-- returns only active ones -- a plan that is not offered is not rendered. That
-- is exactly why the refusal had to land first.
DO $$
DECLARE
    platform_id       UUID := '00000000-0000-0000-0000-000000000000'::UUID;
    platform_admin_id UUID;
    tier              RECORD;
    new_plan_id       UUID;
BEGIN
    SELECT u.id INTO platform_admin_id
      FROM registry.users u
      JOIN registry.tenant_users tu ON tu.user_id = u.id
     WHERE tu.tenant_id = platform_id
     ORDER BY tu.is_primary DESC
     LIMIT 1;

    IF platform_admin_id IS NULL THEN
        RAISE EXCEPTION
            'no platform admin user found; create-default-pricing-relationships '
            'establishes one and must have run before this change';
    END IF;

    FOR tier IN
        SELECT * FROM (VALUES
            ('Studio', 19900, 0.02,  2, 'Everything in Solo, plus multi-location scheduling'),
            ('Empire', 99900, 0.01,  3, 'Everything in Studio, plus priority support')
        ) AS t(plan_name, amount_cents, rate, display_order, description)
    LOOP
        -- Idempotent on the name: a re-deploy after a partial failure must not
        -- put a second Studio on the signup page.
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM registry.pricing_plans
             WHERE plan_name = tier.plan_name AND plan_scope = 'tenant'
        );

        INSERT INTO registry.pricing_plans (
            plan_scope, plan_name, plan_type, pricing_model_type,
            amount_cents, currency, pricing_configuration, metadata
        ) VALUES (
            'tenant', tier.plan_name, 'standard', 'hybrid',
            tier.amount_cents, 'USD',
            jsonb_build_object(
                'percentage',   tier.rate,
                'applies_to',   'customer_payments',
                'description',  tier.description,
                'refund_application_fee', true
            ),
            jsonb_build_object(
                'display_order', tier.display_order,
                'coming_soon',   true,
                'description',   tier.description
            )
        )
        RETURNING id INTO new_plan_id;

        INSERT INTO registry.pricing_relationships (
            provider_id, consumer_id, pricing_plan_id, status, metadata
        ) VALUES (
            platform_id, platform_admin_id, new_plan_id, 'active',
            jsonb_build_object(
                'plan_name',            tier.plan_name,
                'plan_type',            'tenant_subscription',
                'created_by_migration', 'seed-tier-pricing-options'
            )
        );
    END LOOP;
END $$;

-- Exactly one buyable tier, or the page is either empty or offering something
-- that is not ready. Cheaper to fail the deploy than to find out from a signup.
DO $$
DECLARE
    buyable integer;
BEGIN
    SELECT COUNT(*) INTO buyable
      FROM registry.pricing_relationships pr
      JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
     WHERE pr.provider_id = '00000000-0000-0000-0000-000000000000'::UUID
       AND pr.status = 'active'
       AND p.plan_scope = 'tenant'
       AND COALESCE(p.metadata->>'coming_soon', 'false') <> 'true';

    IF buyable <> 1 THEN
        RAISE EXCEPTION
            'expected exactly one buyable tenant tier on offer, found %', buyable;
    END IF;
END $$;

COMMIT;
