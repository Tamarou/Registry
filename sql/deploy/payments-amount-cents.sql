-- ABOUTME: Store payments and payment_items money as integer cents.
-- ABOUTME: Removes the last dollars-to-cents conversion between a price and a charge.

-- Deploy registry:payments-amount-cents to pg
-- requires: pricing-plans-amount-cents

BEGIN;

SET client_min_messages = 'warning';

-- Both columns always meant dollars, so this is a straight rescale -- unlike
-- pricing_plans, where the column doubled as a rate. What it buys is the
-- removal of _to_cents: DECIMAL(10,2) is exact in Postgres but DBD::Pg hands it
-- back as a string, and every numification of that string was a chance to lose
-- a cent on the way to Stripe.

ALTER TABLE registry.payments
    ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0;
UPDATE registry.payments SET amount_cents = ROUND(amount * 100)::INTEGER;
ALTER TABLE registry.payments DROP COLUMN amount;

ALTER TABLE registry.payment_items
    ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0;
UPDATE registry.payment_items SET amount_cents = ROUND(amount * 100)::INTEGER;
ALTER TABLE registry.payment_items DROP COLUMN amount;

-- clone_schema copies structure from registry at call time, so new tenants pick
-- this up on their own. Tenants that already exist do not, and a tenant left on
-- the old column would charge in the wrong units for every family it serves.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Skip tenants that don't have their own schema (e.g. registry-platform)
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.payments
                ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payments SET amount_cents = ROUND(amount * 100)::INTEGER', s);
        EXECUTE format('ALTER TABLE %I.payments DROP COLUMN amount', s);

        EXECUTE format(
            'ALTER TABLE %I.payment_items
                ADD COLUMN IF NOT EXISTS amount_cents INTEGER NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payment_items SET amount_cents = ROUND(amount * 100)::INTEGER', s);
        EXECUTE format('ALTER TABLE %I.payment_items DROP COLUMN amount', s);
    END LOOP;
END $$;

COMMIT;
