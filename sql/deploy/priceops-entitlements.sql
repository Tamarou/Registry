-- ABOUTME: Entitlements: who holds what, who paid, under which stamped offer version and plan, and when.
-- ABOUTME: Built in registry (tenant holders) and every tenant schema (its people and children).

-- Deploy registry:priceops-entitlements to pg
-- requires: priceops-offer-policies

BEGIN;

SET client_min_messages = 'warning';

-- The stamp is what refunds and changes resolve against, so it is fixed at
-- creation: an entitlement is sold under a published version, and neither its
-- version nor its accepted plan is ever re-pointed. Enforced here so psql and
-- fixtures are held to it too. A missing version is left to the foreign key.
-- One shared function; each schema's table gets its own trigger.
CREATE OR REPLACE FUNCTION registry.entitlement_stamp() RETURNS trigger AS $t$
DECLARE
    is_draft boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.offer_version_id, NEW.payment_plan_id)
           IS DISTINCT FROM (OLD.offer_version_id, OLD.payment_plan_id)
        THEN
            RAISE EXCEPTION
                'entitlement % keeps the stamp it was sold under: its offer '
                'version and payment plan cannot change.', OLD.id;
        END IF;
        RETURN NEW;
    END IF;
    EXECUTE format('SELECT published_at IS NULL FROM %I.offer_versions WHERE id = $1',
                   TG_TABLE_SCHEMA) INTO is_draft USING NEW.offer_version_id;
    IF is_draft THEN
        RAISE EXCEPTION 'offer version % is a draft: nothing is sold under it until it is published',
            NEW.offer_version_id;
    END IF;
    RETURN NEW;
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
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        -- A person or child is a studio's holder; a tenant is the platform's,
        -- held in registry. Foreign keys stay within the schema.
        -- The stamp is the exact offer version and which of its payment plans
        -- was accepted, so refunds resolve against the terms it was sold under.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.entitlements (
                id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                -- The holder is who it is for; the payer is set only when
                -- someone else paid, e.g. a parent for a child.
                holder_user_id          uuid REFERENCES %1$I.users (id),
                holder_family_member_id uuid REFERENCES %1$I.family_members (id),
                holder_tenant_id        uuid REFERENCES %1$I.tenants (id),
                payer_user_id           uuid REFERENCES %1$I.users (id),
                offer_version_id        uuid NOT NULL,
                payment_plan_id         text NOT NULL,
                -- Pillar 2's schedule phase: a start and an optional end,
                -- half-open, so a phase ending at T and one starting at T
                -- never overlap.
                in_effect               tstzrange NOT NULL
                    CONSTRAINT entitlements_in_effect_check CHECK (
                        NOT isempty(in_effect) AND NOT lower_inf(in_effect)
                        AND lower_inc(in_effect) AND NOT upper_inc(in_effect)
                    ),
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

        EXECUTE format(
            'DROP TRIGGER IF EXISTS entitlements_stamp ON %I.entitlements', s);
        EXECUTE format($f$
            CREATE TRIGGER entitlements_stamp
                BEFORE INSERT OR UPDATE ON %I.entitlements
                FOR EACH ROW EXECUTE FUNCTION registry.entitlement_stamp()
        $f$, s);
    END LOOP;
END $$;

COMMIT;
