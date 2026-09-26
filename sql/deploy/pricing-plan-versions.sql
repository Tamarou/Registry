-- ABOUTME: Pricing plans become append-only versions, and a charge records the version it used.
-- ABOUTME: Pillars 1 and 2 of PriceOps: immutable plan versions, and a recoverable pricing basis.

-- Deploy registry:pricing-plan-versions to pg
-- requires: session-waitlist-toggle

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Editing a price in place re-prices everybody already on that plan,
-- retroactively, and destroys the only record of what the old price was. The
-- methodology PriceOps is named for calls for an append-only collection of
-- versioned plans whose versions are immutable; this is that.
--
--   id              stays the primary key, and therefore what a charge, a
--                   tenant link or a schedule points AT -- a specific version.
--   plan_family_id  the stable identity shared by every version of one plan.
--                   For a first version it equals id.
--   version         1, 2, 3 ... within a family.
--   superseded_at   set when a newer version replaces this one. NULL means
--                   current, and exactly one version per family may be current.
--
-- Nothing in lib/ has ever updated a pricing plan, so no behaviour changes
-- today. The door is being closed before the plan-editing screen (#427) is
-- built, because afterwards would mean migrating rows that had already lost
-- their history.
ALTER TABLE pricing_plans
    ADD COLUMN IF NOT EXISTS plan_family_id uuid,
    ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS superseded_at timestamp with time zone;

-- Existing rows are each the first version of their own family.
UPDATE pricing_plans SET plan_family_id = id WHERE plan_family_id IS NULL;

ALTER TABLE pricing_plans ALTER COLUMN plan_family_id SET NOT NULL;

-- A first version is its own family, and the value is the row's own generated
-- id -- which no DEFAULT can reference. Done in a trigger rather than in the DAO
-- so the invariant holds for every writer: raw SQL, a seed migration, a fixture,
-- and the tenant copies of this table alike. The DAO cannot supply it either,
-- because the id it would need does not exist until the insert returns.
CREATE OR REPLACE FUNCTION registry.pricing_plan_family_default() RETURNS trigger AS $t$
BEGIN
    IF NEW.plan_family_id IS NULL THEN
        NEW.plan_family_id := NEW.id;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS pricing_plans_family_default ON pricing_plans;
CREATE TRIGGER pricing_plans_family_default
    BEFORE INSERT ON pricing_plans
    FOR EACH ROW EXECUTE FUNCTION registry.pricing_plan_family_default();

-- A family cannot have two of the same version, and cannot have two current
-- ones. The partial index is what makes "the current version" a question with
-- one answer rather than an ordering convention -- get_pricing_plans has no
-- ORDER BY, and relying on return order is how the enrolment cart came to charge
-- whichever price Postgres handed back first.
CREATE UNIQUE INDEX IF NOT EXISTS pricing_plans_family_version_key
    ON pricing_plans (plan_family_id, version);
CREATE UNIQUE INDEX IF NOT EXISTS pricing_plans_one_current_per_family
    ON pricing_plans (plan_family_id) WHERE superseded_at IS NULL;

-- Immutability enforced HERE, not in the DAO.
--
-- A Perl croak is not immutability: `UPDATE pricing_plans SET amount_cents = ...`
-- in psql works regardless, and psql is the only pricing tooling the platform
-- owner currently has (#426) -- so the one person most likely to edit a plan row
-- is the one with no other way to. RevenueShare reads the rate off the row on
-- every charge, so a hand-edit silently re-prices.
--
-- The allowed set is expressed as a subtraction rather than a list of protected
-- columns, so a column added to this table later is protected automatically.
-- Listing what is guarded would fail open on the next migration.
--
-- superseded_at is exempt because retiring a version is not changing its terms;
-- updated_at because the existing update_updated_at_column trigger sets it.
CREATE OR REPLACE FUNCTION registry.pricing_plan_terms_immutable() RETURNS trigger AS $t$
BEGIN
    IF ( to_jsonb(NEW) - 'superseded_at' - 'updated_at' )
       IS DISTINCT FROM
       ( to_jsonb(OLD) - 'superseded_at' - 'updated_at' )
    THEN
        RAISE EXCEPTION
            'pricing_plans rows are immutable (plan % version %): append a new '
            'version instead of editing this one. Only superseded_at may change.',
            OLD.plan_family_id, OLD.version;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS pricing_plans_terms_immutable ON pricing_plans;
CREATE TRIGGER pricing_plans_terms_immutable
    BEFORE UPDATE ON pricing_plans
    FOR EACH ROW EXECUTE FUNCTION registry.pricing_plan_terms_immutable();

-- The pricing basis of a charge. Without this the plan a customer was charged
-- under is recorded nowhere: payment_items carries an amount and a description,
-- and with plans previously mutable the amount did not even imply the plan.
-- No FK, deliberately -- pricing_plans lives per tenant schema and a line item
-- must survive a plan family being pruned; this is a historical record, not a
-- live reference.
ALTER TABLE payment_items
    ADD COLUMN IF NOT EXISTS pricing_plan_id uuid;

CREATE INDEX IF NOT EXISTS payment_items_pricing_plan_id_idx
    ON payment_items (pricing_plan_id) WHERE pricing_plan_id IS NOT NULL;

-- Every tenant keeps its own copy of both tables. A column added only to
-- registry is a column the customer schemas do not have, and the tenant schemas
-- are where the programmes and the charges actually live.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        -- Schema existence is not table existence: a half-provisioned tenant
        -- would otherwise abort the whole migration.
        IF to_regclass(format('%I.pricing_plans', s)) IS NOT NULL THEN
            EXECUTE format($f$
                ALTER TABLE %I.pricing_plans
                    ADD COLUMN IF NOT EXISTS plan_family_id uuid,
                    ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1,
                    ADD COLUMN IF NOT EXISTS superseded_at timestamp with time zone
            $f$, s);
            EXECUTE format(
                'UPDATE %I.pricing_plans SET plan_family_id = id WHERE plan_family_id IS NULL', s);
            EXECUTE format(
                'ALTER TABLE %I.pricing_plans ALTER COLUMN plan_family_id SET NOT NULL', s);

            -- One shared function in registry; each tenant table gets its own
            -- trigger pointing at it.
            EXECUTE format(
                'DROP TRIGGER IF EXISTS pricing_plans_family_default ON %I.pricing_plans', s);
            EXECUTE format($f$
                CREATE TRIGGER pricing_plans_family_default
                    BEFORE INSERT ON %I.pricing_plans
                    FOR EACH ROW EXECUTE FUNCTION registry.pricing_plan_family_default()
            $f$, s);

            EXECUTE format(
                'DROP TRIGGER IF EXISTS pricing_plans_terms_immutable ON %I.pricing_plans', s);
            EXECUTE format($f$
                CREATE TRIGGER pricing_plans_terms_immutable
                    BEFORE UPDATE ON %I.pricing_plans
                    FOR EACH ROW EXECUTE FUNCTION registry.pricing_plan_terms_immutable()
            $f$, s);
            EXECUTE format($f$
                CREATE UNIQUE INDEX IF NOT EXISTS pricing_plans_family_version_key
                    ON %I.pricing_plans (plan_family_id, version)
            $f$, s);
            EXECUTE format($f$
                CREATE UNIQUE INDEX IF NOT EXISTS pricing_plans_one_current_per_family
                    ON %I.pricing_plans (plan_family_id) WHERE superseded_at IS NULL
            $f$, s);
        END IF;

        IF to_regclass(format('%I.payment_items', s)) IS NOT NULL THEN
            EXECUTE format(
                'ALTER TABLE %I.payment_items ADD COLUMN IF NOT EXISTS pricing_plan_id uuid', s);
            EXECUTE format($f$
                CREATE INDEX IF NOT EXISTS payment_items_pricing_plan_id_idx
                    ON %I.payment_items (pricing_plan_id) WHERE pricing_plan_id IS NOT NULL
            $f$, s);
        END IF;
    END LOOP;
END $$;

COMMIT;
