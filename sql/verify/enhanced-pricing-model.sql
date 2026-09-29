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
--
-- installments_allowed and installment_count are absent for the same reason.
-- instalments-declared-in-configuration drops them -- the offer is declared in
-- pricing_configuration now, where it can carry a cadence and a surcharge -- so
-- naming them here would make this verify unpassable on any database that has
-- caught up. A check that cannot pass is worse than no check: it trains whoever
-- runs `sqitch verify` to read a failure and shrug.
SELECT id, session_id, plan_name, plan_type, requirements
FROM pricing_plans
WHERE FALSE;

-- Verify no old pricing table exists
SELECT 1 FROM information_schema.tables 
WHERE table_schema = 'registry' 
AND table_name = 'pricing'
HAVING COUNT(*) = 0;

ROLLBACK;