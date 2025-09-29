-- ABOUTME: Reverts the pricing relationship events table and related objects
-- ABOUTME: Removes event sourcing infrastructure for pricing relationships

-- Revert registry:pricing-relationship-events from pg

BEGIN;

-- Drop the view
DROP VIEW IF EXISTS registry.pricing_relationship_current_state;

-- Drop functions
DROP FUNCTION IF EXISTS get_relationship_state_at(UUID, TIMESTAMP WITH TIME ZONE);
DROP FUNCTION IF EXISTS get_next_aggregate_version(UUID);
DROP FUNCTION IF EXISTS ensure_event_sequence();

-- Drop the events table
DROP TABLE IF EXISTS registry.pricing_relationship_events CASCADE;

COMMIT;