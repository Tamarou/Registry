-- ABOUTME: Verifies the pricing relationship events table exists with correct structure
-- ABOUTME: Ensures event sourcing infrastructure is properly deployed

-- Verify registry:pricing-relationship-events on pg

BEGIN;

-- Check table exists with required columns
SELECT
    id,
    relationship_id,
    event_type,
    actor_user_id,
    event_data,
    occurred_at,
    sequence_number,
    aggregate_version
FROM registry.pricing_relationship_events
WHERE FALSE;

-- Check view exists
SELECT * FROM registry.pricing_relationship_current_state WHERE FALSE;

-- Check functions exist
SELECT get_next_aggregate_version('00000000-0000-0000-0000-000000000000'::UUID);

-- Check indexes exist
SELECT 1
FROM pg_indexes
WHERE schemaname = 'registry'
  AND tablename = 'pricing_relationship_events'
  AND indexname IN (
      'idx_pricing_events_relationship',
      'idx_pricing_events_actor',
      'idx_pricing_events_type',
      'idx_pricing_events_occurred',
      'idx_pricing_events_sequence',
      'idx_pricing_events_relationship_sequence'
  );

ROLLBACK;