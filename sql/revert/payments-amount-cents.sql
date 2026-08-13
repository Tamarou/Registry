-- ABOUTME: Restore payments and payment_items to DECIMAL(10,2) dollars.
-- ABOUTME: Cents divide back exactly; DECIMAL(10,2) holds every value they can carry.

-- Revert registry:payments-amount-cents from pg

BEGIN;

SET client_min_messages = 'warning';

-- DEFAULT 0 is scaffolding: ADD COLUMN ... NOT NULL needs a value for the
-- existing rows.  payments.sql:10,33 declared these columns bare NOT NULL, so
-- the default is dropped once the backfill has run -- otherwise an INSERT that
-- omits the amount books a zero payment instead of raising.
ALTER TABLE registry.payments
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payments SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.payments ALTER COLUMN amount DROP DEFAULT;
ALTER TABLE registry.payments DROP COLUMN amount_cents;

-- performance-optimization.sql:68 indexed this column, and DROP COLUMN in the
-- deploy took the index with it.  Restoring the column without the index leaves
-- the schema short of what the revert claims to restore.
CREATE INDEX IF NOT EXISTS idx_payments_amount ON registry.payments(amount);

ALTER TABLE registry.payment_items
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payment_items SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.payment_items ALTER COLUMN amount DROP DEFAULT;
ALTER TABLE registry.payment_items DROP COLUMN amount_cents;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.payments
                ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payments SET amount = amount_cents::DECIMAL / 100', s);
        EXECUTE format('ALTER TABLE %I.payments ALTER COLUMN amount DROP DEFAULT', s);
        EXECUTE format('ALTER TABLE %I.payments DROP COLUMN amount_cents', s);

        -- Unnamed, so Postgres generates payments_amount_idx -- the same name
        -- clone_schema's LIKE ... INCLUDING ALL gave the tenant copy.
        EXECUTE format('CREATE INDEX ON %I.payments (amount)', s);

        EXECUTE format(
            'ALTER TABLE %I.payment_items
                ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payment_items SET amount = amount_cents::DECIMAL / 100', s);
        EXECUTE format('ALTER TABLE %I.payment_items ALTER COLUMN amount DROP DEFAULT', s);
        EXECUTE format('ALTER TABLE %I.payment_items DROP COLUMN amount_cents', s);
    END LOOP;
END $$;

COMMIT;
