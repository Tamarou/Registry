-- ABOUTME: Revert migration to remove default pricing relationships for platform pricing plans
-- ABOUTME: Removes pricing relationships created by the deployment migration

-- Revert registry:create-default-pricing-relationships from pg

BEGIN;

-- Remove pricing relationships created by this migration
DELETE FROM registry.pricing_relationships
WHERE metadata->>'created_by_migration' = 'create-default-pricing-relationships';

COMMIT;