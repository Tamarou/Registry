-- ABOUTME: Verifies payments.platform_fee_refunded_cents exists, nullable, in registry.
-- ABOUTME: NULL is load-bearing: it means no refund reported, and counts the full fee.

-- Verify registry:payments-platform-fee-refunded

SELECT 1/(COUNT(*))::int
  FROM information_schema.columns
 WHERE table_schema = 'registry' AND table_name = 'payments'
   AND column_name = 'platform_fee_refunded_cents' AND is_nullable = 'YES';
