-- Verify registry:enhanced-pricing-model on pg

BEGIN;

SET search_path TO registry, public;

-- Verify table was renamed
SELECT 1 FROM information_schema.tables 
WHERE table_schema = 'registry' 
AND table_name = 'pricing_plans';

-- Verify new columns exist
SELECT id, session_id, plan_name, plan_type, amount, 
       installments_allowed, installment_count, requirements
FROM pricing_plans
WHERE FALSE;

-- Verify no old pricing table exists
SELECT 1 FROM information_schema.tables 
WHERE table_schema = 'registry' 
AND table_name = 'pricing'
HAVING COUNT(*) = 0;

ROLLBACK;