-- Verify registry:enhanced-pricing-model on pg

BEGIN;

SET search_path TO registry, public;

-- Verify table was renamed
SELECT 1 FROM information_schema.tables 
WHERE table_schema = 'registry' 
AND table_name = 'pricing_plans';

-- Verify new columns exist. The money column is deliberately absent: this
-- change did not introduce it, and a later change renames it, so asserting it
-- here would fail once that change deploys.
SELECT id, session_id, plan_name, plan_type,
       installments_allowed, installment_count, requirements
FROM pricing_plans
WHERE FALSE;

-- Verify no old pricing table exists
SELECT 1 FROM information_schema.tables 
WHERE table_schema = 'registry' 
AND table_name = 'pricing'
HAVING COUNT(*) = 0;

ROLLBACK;