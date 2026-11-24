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

        -- A person or child is a studio's holder; a tenant is the platform's,
        -- so only registry's tenants table has rows to name.
        -- The stamp is the exact offer version and which of its payment plans
        -- was accepted, so refunds resolve against the terms it was sold under.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.entitlements (
                id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                -- The holder is who it is for; the payer is set only when
                -- someone else paid, e.g. a parent for a child.
                holder_user_id          uuid,
                holder_family_member_id uuid,
                holder_tenant_id        uuid,
                payer_user_id           uuid,
                offer_version_id        uuid NOT NULL,
                payment_plan_id         text NOT NULL,
                -- Pillar 2's schedule phase: a start and an optional end,
                -- half-open, so a phase ending at T and one starting at T
                -- never overlap.
                in_effect               tstzrange NOT NULL,
                created_at              timestamp with time zone NOT NULL DEFAULT now(),
                CONSTRAINT entitlements_one_holder CHECK (
                    num_nonnulls(holder_user_id, holder_family_member_id, holder_tenant_id) = 1
                ),
                -- The plan must be one of the stamped version's own plans.
                CONSTRAINT entitlements_payment_plan_fkey
                    FOREIGN KEY (offer_version_id, payment_plan_id)
                    REFERENCES %1$I.offer_version_payment_plans (offer_version_id, id)
            )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
