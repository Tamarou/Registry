-- Deploy registry:payments-record-platform-fee to pg
-- requires: magic-link-expiry-one-hour

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- What the platform actually took on a charge, and the plan version it took it
-- under.
--
-- Until now neither was recorded anywhere: Payment::_connect_params computes
-- application_fee_cents(), sends it to Stripe, and keeps nothing. So the
-- platform's own revenue existed only inside Stripe, and any figure Registry
-- displayed could only be DERIVED -- amount x current rate -- which disagrees
-- with what was charged on every rate change (#277 moves a tenant between plan
-- versions), on every refund that returns the fee
-- (pricing_configuration.refund_application_fee), and wherever Stripe's
-- rounding differs from ours.
--
-- #427 names recording the plan version on the charge as the cheapest first
-- step towards measurable pricing, and this is it: without it no pricing
-- experiment can be measured even retrospectively.
--
-- NULLABLE on purpose. NULL means "not recorded", which is the honest state for
-- every charge made before this migration and for any charge with no
-- destination (a registry/platform payment has no application fee at all).
-- Zero would claim the platform took nothing, which is a different and
-- sometimes false statement.
ALTER TABLE payments
  ADD COLUMN IF NOT EXISTS platform_fee_cents integer,
  ADD COLUMN IF NOT EXISTS platform_pricing_plan_id uuid;

ALTER TABLE payments
  ADD CONSTRAINT payments_platform_fee_cents_check
  CHECK (platform_fee_cents IS NULL OR platform_fee_cents >= 0);

COMMENT ON COLUMN payments.platform_fee_cents IS
  'Application fee Stripe reported taking on this charge, in cents. NULL means '
  'not recorded: a charge made before this column existed, or one with no '
  'destination account. Never derived from a rate -- see #427.';
COMMENT ON COLUMN payments.platform_pricing_plan_id IS
  'The pricing_plans row (a specific version) the fee above was charged under, '
  'copied from tenants.platform_pricing_plan_id at settlement. Deliberately not '
  'a foreign key: a plan version may be retired, and the charge still happened.';

-- Per-tenant revenue sums walk completed payments; the tenant comes from
-- metadata, so this is the index those sums will use.
CREATE INDEX IF NOT EXISTS idx_payments_platform_fee
    ON payments (platform_pricing_plan_id)
 WHERE platform_fee_cents IS NOT NULL;

-- Propagate to tenant schemas: payments are per-tenant, so every tenant schema
-- carries its own copy of this table.
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- A tenant row whose schema was never built, or was built without this
        -- table. `registry-platform` is exactly that in production -- the shape
        -- #265 and the fleet screen are about -- and iterating it blind is how
        -- this migration failed its first deploy. The same guard every recent
        -- migration uses (#176 wants it standardised).
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        EXECUTE format('ALTER TABLE %I.payments
            ADD COLUMN IF NOT EXISTS platform_fee_cents integer,
            ADD COLUMN IF NOT EXISTS platform_pricing_plan_id uuid;', s);
        EXECUTE format('ALTER TABLE %I.payments
            ADD CONSTRAINT payments_platform_fee_cents_check
            CHECK (platform_fee_cents IS NULL OR platform_fee_cents >= 0);', s);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_payments_platform_fee
            ON %I.payments (platform_pricing_plan_id)
         WHERE platform_fee_cents IS NOT NULL;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
