-- ABOUTME: Re-activate only the relationships this change suspended.
-- ABOUTME: The migration stamp is the handle; rows suspended for other reasons stay suspended.

-- Revert registry:retire-registry-plus-plan from pg

BEGIN;

SET client_min_messages = 'warning';

-- status = 'suspended' as well as the stamp: the stamp records who suspended the
-- row, not what state it is in now.  A row an operator has since cancelled must
-- stay cancelled rather than be resurrected as 'active'.
UPDATE registry.pricing_relationships
   SET status     = 'active',
       metadata   = metadata - 'suspended_by_migration',
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'
   AND status = 'suspended';

COMMIT;
