-- ABOUTME: Creates event sourcing table for pricing relationships audit trail
-- ABOUTME: Tracks all state changes for compliance, analytics, and dispute resolution

-- Deploy registry:pricing-relationship-events to pg
-- requires: consolidate-pricing-relationships

BEGIN;

-- Create the event sourcing table for pricing relationships
CREATE TABLE registry.pricing_relationship_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    relationship_id UUID NOT NULL REFERENCES registry.pricing_relationships(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    actor_user_id UUID NOT NULL REFERENCES registry.users(id),
    event_data JSONB NOT NULL DEFAULT '{}',
    occurred_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Event sourcing integrity fields
    sequence_number BIGSERIAL NOT NULL,
    aggregate_version INTEGER NOT NULL DEFAULT 1,

    -- Constraints
    CONSTRAINT valid_event_type CHECK (event_type IN (
        'created', 'activated', 'suspended', 'terminated',
        'plan_changed', 'billing_updated', 'metadata_updated'
    ))
);

-- Create indexes for efficient querying
CREATE INDEX idx_pricing_events_relationship ON registry.pricing_relationship_events(relationship_id);
CREATE INDEX idx_pricing_events_actor ON registry.pricing_relationship_events(actor_user_id);
CREATE INDEX idx_pricing_events_type ON registry.pricing_relationship_events(event_type);
CREATE INDEX idx_pricing_events_occurred ON registry.pricing_relationship_events(occurred_at DESC);
CREATE INDEX idx_pricing_events_sequence ON registry.pricing_relationship_events(relationship_id, sequence_number DESC);

-- Unique constraint to prevent duplicate sequence numbers per relationship
CREATE UNIQUE INDEX idx_pricing_events_relationship_sequence
    ON registry.pricing_relationship_events(relationship_id, sequence_number);

-- Function to get next aggregate version for a relationship
CREATE OR REPLACE FUNCTION get_next_aggregate_version(p_relationship_id UUID)
RETURNS INTEGER AS $$
DECLARE
    v_version INTEGER;
BEGIN
    SELECT COALESCE(MAX(aggregate_version), 0) + 1
    INTO v_version
    FROM registry.pricing_relationship_events
    WHERE relationship_id = p_relationship_id;

    RETURN v_version;
END;
$$ LANGUAGE plpgsql;

-- Function to ensure sequence integrity
CREATE OR REPLACE FUNCTION ensure_event_sequence()
RETURNS TRIGGER AS $$
DECLARE
    v_last_sequence BIGINT;
    v_expected_version INTEGER;
BEGIN
    -- Get the last sequence number for this relationship
    SELECT COALESCE(MAX(sequence_number), 0)
    INTO v_last_sequence
    FROM registry.pricing_relationship_events
    WHERE relationship_id = NEW.relationship_id
    AND id != NEW.id;

    -- Get expected aggregate version
    v_expected_version := get_next_aggregate_version(NEW.relationship_id);

    -- Verify aggregate version matches
    IF NEW.aggregate_version != v_expected_version THEN
        RAISE EXCEPTION 'Aggregate version mismatch. Expected %, got %',
            v_expected_version, NEW.aggregate_version;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to ensure event sequence integrity
CREATE TRIGGER ensure_pricing_event_sequence
    BEFORE INSERT ON registry.pricing_relationship_events
    FOR EACH ROW EXECUTE FUNCTION ensure_event_sequence();

-- View for latest relationship state from events
CREATE OR REPLACE VIEW registry.pricing_relationship_current_state AS
WITH latest_events AS (
    SELECT DISTINCT ON (relationship_id)
        relationship_id,
        event_type,
        event_data,
        occurred_at,
        actor_user_id
    FROM registry.pricing_relationship_events
    ORDER BY relationship_id, sequence_number DESC
)
SELECT
    pr.id,
    pr.provider_id,
    pr.consumer_id,
    pr.pricing_plan_id,
    pr.status,
    pr.metadata,
    le.event_type as last_event_type,
    le.occurred_at as last_event_at,
    le.actor_user_id as last_actor_id,
    pr.created_at,
    pr.updated_at
FROM registry.pricing_relationships pr
LEFT JOIN latest_events le ON le.relationship_id = pr.id;

-- Function to reconstruct relationship state at a point in time
CREATE OR REPLACE FUNCTION get_relationship_state_at(
    p_relationship_id UUID,
    p_timestamp TIMESTAMP WITH TIME ZONE
) RETURNS TABLE(
    relationship_id UUID,
    status TEXT,
    pricing_plan_id UUID,
    metadata JSONB,
    last_event_type TEXT,
    last_event_at TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    WITH events_before AS (
        SELECT
            event_type,
            event_data,
            occurred_at
        FROM registry.pricing_relationship_events pre
        WHERE pre.relationship_id = p_relationship_id
        AND pre.occurred_at <= p_timestamp
        ORDER BY pre.sequence_number DESC
        LIMIT 1
    ),
    base_relationship AS (
        SELECT
            pr.id,
            pr.pricing_plan_id as original_plan_id,
            pr.metadata as original_metadata
        FROM registry.pricing_relationships pr
        WHERE pr.id = p_relationship_id
    )
    SELECT
        br.id as relationship_id,
        CASE
            WHEN eb.event_type = 'terminated' THEN 'cancelled'
            WHEN eb.event_type = 'suspended' THEN 'suspended'
            WHEN eb.event_type IN ('activated', 'created') THEN 'active'
            ELSE 'unknown'
        END as status,
        COALESCE((eb.event_data->>'new_plan_id')::UUID, br.original_plan_id) as pricing_plan_id,
        COALESCE(eb.event_data->'new_metadata', br.original_metadata) as metadata,
        eb.event_type as last_event_type,
        eb.occurred_at as last_event_at
    FROM base_relationship br
    LEFT JOIN events_before eb ON true;
END;
$$ LANGUAGE plpgsql;

-- Grant permissions (web role may not exist in test environment)
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'web') THEN
        GRANT SELECT, INSERT ON registry.pricing_relationship_events TO web;
        GRANT USAGE ON SEQUENCE registry.pricing_relationship_events_sequence_number_seq TO web;
        GRANT SELECT ON registry.pricing_relationship_current_state TO web;
        GRANT EXECUTE ON FUNCTION get_next_aggregate_version(UUID) TO web;
        GRANT EXECUTE ON FUNCTION get_relationship_state_at(UUID, TIMESTAMP WITH TIME ZONE) TO web;
    END IF;
END $$;

COMMIT;