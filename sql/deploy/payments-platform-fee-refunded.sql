-- ABOUTME: payments.platform_fee_refunded_cents: how much of the platform fee Stripe reports returned, in every schema.
-- ABOUTME: NULL is none reported; application_fee.refunded only ever raises it.

-- Deploy registry:payments-platform-fee-refunded to pg
-- requires: pricing-plan-rate-check

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE payments
  ADD COLUMN platform_fee_refunded_cents integer
  CONSTRAINT payments_platform_fee_refunded_cents_check
  CHECK (platform_fee_refunded_cents IS NULL OR platform_fee_refunded_cents >= 0);

COMMENT ON COLUMN payments.platform_fee_refunded_cents IS
  'Of platform_fee_cents, what Stripe reports returned (application_fee.refunded '
  'amount_refunded). NULL means none reported. Raised, never lowered.';

-- Payments are per tenant; new tenants get the column through clone_schema.
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        EXECUTE format('ALTER TABLE %I.payments
            ADD COLUMN platform_fee_refunded_cents integer
            CONSTRAINT payments_platform_fee_refunded_cents_check
            CHECK (platform_fee_refunded_cents IS NULL OR platform_fee_refunded_cents >= 0);', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
