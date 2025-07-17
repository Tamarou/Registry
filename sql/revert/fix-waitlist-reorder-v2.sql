-- Revert registry:fix-waitlist-reorder-v2 from pg

BEGIN;

-- Revert back to the previous version of the reorder function
-- This would restore the fix-waitlist-reorder version

-- For now, just acknowledge the revert
-- The previous version can be restored by re-running fix-waitlist-reorder migration

COMMIT;