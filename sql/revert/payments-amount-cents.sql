-- ABOUTME: Restore payments and payment_items to DECIMAL(10,2) dollars.
-- ABOUTME: Cents divide back exactly; DECIMAL(10,2) holds every value they can carry.

-- Revert registry:payments-amount-cents from pg

BEGIN;

SET client_min_messages = 'warning';

ALTER TABLE registry.payments
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payments SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.payments DROP COLUMN amount_cents;

ALTER TABLE registry.payment_items
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payment_items SET amount = amount_cents::DECIMAL / 100;
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
        EXECUTE format('ALTER TABLE %I.payments DROP COLUMN amount_cents', s);

        EXECUTE format(
            'ALTER TABLE %I.payment_items
                ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payment_items SET amount = amount_cents::DECIMAL / 100', s);
        EXECUTE format('ALTER TABLE %I.payment_items DROP COLUMN amount_cents', s);
    END LOOP;
END $$;

COMMIT;
