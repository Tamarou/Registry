-- Revert registry:fix-waitlist-reorder-v3 from pg

BEGIN;

-- Revert back to the previous version by re-running fix-waitlist-reorder-v2
-- This would restore the trigger functions

COMMIT;