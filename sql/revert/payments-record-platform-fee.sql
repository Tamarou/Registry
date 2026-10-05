-- Revert registry:payments-record-platform-fee from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP INDEX IF EXISTS idx_payments_platform_fee;
ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_platform_fee_cents_check;
ALTER TABLE payments
  DROP COLUMN IF EXISTS platform_fee_cents,
  DROP COLUMN IF EXISTS platform_pricing_plan_id;

DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        EXECUTE format('DROP INDEX IF EXISTS %I.idx_payments_platform_fee;', s);
        EXECUTE format('ALTER TABLE %I.payments
            DROP CONSTRAINT IF EXISTS payments_platform_fee_cents_check;', s);
        EXECUTE format('ALTER TABLE %I.payments
            DROP COLUMN IF EXISTS platform_fee_cents,
            DROP COLUMN IF EXISTS platform_pricing_plan_id;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
