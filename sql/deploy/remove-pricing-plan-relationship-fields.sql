-- ABOUTME: Migration to remove obsolete relationship fields from pricing_plans table
-- ABOUTME: Clean separation: plans define WHAT is offered, relationships define WHO gets access

-- Deploy registry:remove-pricing-plan-relationship-fields to pg
-- requires: pricing-relationship-events

BEGIN;

-- Remove obsolete columns from pricing_plans table
-- These fields violate separation of concerns - relationships belong in pricing_relationships table
ALTER TABLE registry.pricing_plans
    DROP COLUMN IF EXISTS target_tenant_id,
    DROP COLUMN IF EXISTS offering_tenant_id;

-- Add comment to clarify the table's purpose
COMMENT ON TABLE registry.pricing_plans IS
'Defines pricing plans (what is offered) - relationship-agnostic.
WHO gets access is handled by pricing_relationships table.
Plans can have different scopes: customer (B2C), tenant (B2B), or platform (infrastructure).';

COMMIT;