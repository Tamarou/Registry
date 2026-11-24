-- ABOUTME: Entitlements: who holds what, who paid, under which stamped offer version and plan, and when.
-- ABOUTME: Built in registry (tenant holders) and every tenant schema (its people and children).

-- Deploy registry:priceops-entitlements to pg
-- requires: priceops-offer-policies

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        -- The stamp is the exact offer version and which of its payment plans
        -- was accepted, so refunds resolve against the terms it was sold under.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.entitlements (
                id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                holder_user_id   uuid,
                offer_version_id uuid NOT NULL,
                payment_plan_id  text NOT NULL,
                created_at       timestamp with time zone NOT NULL DEFAULT now()
            )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
