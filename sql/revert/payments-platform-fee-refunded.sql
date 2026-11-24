-- ABOUTME: Drops payments.platform_fee_refunded_cents from registry and every tenant schema.
-- ABOUTME: The refunded fees it held are lost; Stripe still has them.

-- Revert registry:payments-platform-fee-refunded from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE payments DROP COLUMN IF EXISTS platform_fee_refunded_cents;

DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        EXECUTE format('ALTER TABLE %I.payments
            DROP COLUMN IF EXISTS platform_fee_refunded_cents;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
