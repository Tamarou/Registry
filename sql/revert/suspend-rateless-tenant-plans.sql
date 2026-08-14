-- ABOUTME: Restore the pricing relationships this change suspended.
-- ABOUTME: Only rows stamped by the deploy are touched, so unrelated suspensions survive.

-- Revert registry:suspend-rateless-tenant-plans from pg

BEGIN;

UPDATE registry.pricing_relationships
   SET status     = 'active',
       metadata   = metadata - 'suspended_by_migration',
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'suspended_by_migration' = 'suspend-rateless-tenant-plans';

COMMIT;
