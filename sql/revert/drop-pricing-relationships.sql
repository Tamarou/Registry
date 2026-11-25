-- ABOUTME: Recreate pricing_relationships, its event log, view and functions, and billing_periods.
-- ABOUTME: LOSSY -- structure only, in registry and every tenant schema; dropped rows cannot be recovered.

-- Revert registry:drop-pricing-relationships from pg

-- LOSSY REVERT.  The deploy DROPs the tables, so their rows are gone.  Nothing
-- has written pricing_relationships since #427 and nothing outside their own
-- DAOs read the event log or billing_periods, so the issue accepts that.  This
-- script restores structure: every column, index, constraint, trigger, view and
-- function, under the names the original chain gave them.

BEGIN;

SET client_min_messages = 'warning';

CREATE TABLE registry.pricing_relationships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider_id UUID NOT NULL REFERENCES registry.tenants(id),
    consumer_id UUID NOT NULL REFERENCES registry.users(id),
    pricing_plan_id UUID NOT NULL REFERENCES registry.pricing_plans(id),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('pending', 'active', 'suspended', 'cancelled')),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_pricing_relationships_provider ON registry.pricing_relationships(provider_id);
CREATE INDEX idx_pricing_relationships_consumer ON registry.pricing_relationships(consumer_id);
CREATE INDEX idx_pricing_relationships_status ON registry.pricing_relationships(status) WHERE status IN ('active', 'pending');
CREATE INDEX idx_pricing_relationships_plan ON registry.pricing_relationships(pricing_plan_id);

CREATE TRIGGER update_pricing_relationships_updated_at
    BEFORE UPDATE ON registry.pricing_relationships
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- The column order is the one consolidate-pricing-relationships left behind:
-- pricing_relationship_id was re-added last, and its key kept the _new_ name.
CREATE TABLE registry.billing_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    calculated_amount DECIMAL(10,2) NOT NULL,
    payment_status VARCHAR(50) DEFAULT 'pending'
        CHECK (payment_status IN ('pending', 'processing', 'paid', 'failed', 'refunded')),
    stripe_invoice_id VARCHAR(255),
    stripe_payment_intent_id VARCHAR(255),
    processed_at TIMESTAMP WITH TIME ZONE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    pricing_relationship_id UUID NOT NULL
);

ALTER TABLE registry.billing_periods
    ADD CONSTRAINT billing_periods_pricing_relationship_id_new_fkey
    FOREIGN KEY (pricing_relationship_id) REFERENCES registry.pricing_relationships(id);

CREATE INDEX idx_billing_periods_status ON registry.billing_periods(payment_status);
CREATE INDEX idx_billing_periods_period ON registry.billing_periods(period_start, period_end);

CREATE TRIGGER update_billing_periods_updated_at
    BEFORE UPDATE ON registry.billing_periods
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TABLE registry.pricing_relationship_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    relationship_id UUID NOT NULL REFERENCES registry.pricing_relationships(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    actor_user_id UUID NOT NULL REFERENCES registry.users(id),
    event_data JSONB NOT NULL DEFAULT '{}',
    occurred_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sequence_number BIGSERIAL NOT NULL,
    aggregate_version INTEGER NOT NULL DEFAULT 1,
    CONSTRAINT valid_event_type CHECK (event_type IN (
        'created', 'activated', 'suspended', 'terminated',
        'plan_changed', 'billing_updated', 'metadata_updated'
    ))
);

-- Same order as pricing-relationship-events.sql, so that a tenant's LIKE copy
-- numbers its two (relationship_id, sequence_number) indexes the same way.
CREATE INDEX idx_pricing_events_relationship ON registry.pricing_relationship_events(relationship_id);
CREATE INDEX idx_pricing_events_actor ON registry.pricing_relationship_events(actor_user_id);
CREATE INDEX idx_pricing_events_type ON registry.pricing_relationship_events(event_type);
CREATE INDEX idx_pricing_events_occurred ON registry.pricing_relationship_events(occurred_at DESC);
CREATE INDEX idx_pricing_events_sequence ON registry.pricing_relationship_events(relationship_id, sequence_number DESC);
CREATE UNIQUE INDEX idx_pricing_events_relationship_sequence
    ON registry.pricing_relationship_events(relationship_id, sequence_number);

-- Bodies verbatim from pricing-relationship-events.sql: they are compared as text.
CREATE OR REPLACE FUNCTION public.get_next_aggregate_version(p_relationship_id UUID)
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

CREATE OR REPLACE FUNCTION public.ensure_event_sequence()
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

CREATE OR REPLACE FUNCTION public.get_relationship_state_at(
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

CREATE TRIGGER ensure_pricing_event_sequence
    BEFORE INSERT ON registry.pricing_relationship_events
    FOR EACH ROW EXECUTE FUNCTION public.ensure_event_sequence();

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

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'web') THEN
        GRANT SELECT, INSERT, UPDATE ON registry.pricing_relationships TO web;
        GRANT SELECT, INSERT, UPDATE ON registry.billing_periods TO web;
        GRANT SELECT, INSERT ON registry.pricing_relationship_events TO web;
        GRANT USAGE ON SEQUENCE registry.pricing_relationship_events_sequence_number_seq TO web;
        GRANT SELECT ON registry.pricing_relationship_current_state TO web;
        GRANT EXECUTE ON FUNCTION public.get_next_aggregate_version(UUID) TO web;
        GRANT EXECUTE ON FUNCTION public.get_relationship_state_at(UUID, TIMESTAMP WITH TIME ZONE) TO web;
    END IF;
END $$;

-- Tenant copies, built the way clone_schema builds them: LIKE ... INCLUDING ALL
-- (indexes, defaults, checks), then foreign keys onto the tenant's own tables,
-- then triggers, then the view.  clone_schema's sequence copy is a free-standing
-- sequence in the tenant schema that the column default points at.
--
-- The to_regclass guard skips the seeded 'registry' tenant, whose tables the
-- statements above have already created.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        CONTINUE WHEN to_regclass(format('%I.pricing_relationships', s)) IS NOT NULL;

        EXECUTE format('CREATE SEQUENCE %I.pricing_relationship_events_sequence_number_seq', s);

        EXECUTE format('CREATE TABLE %I.pricing_relationships (LIKE registry.pricing_relationships INCLUDING ALL)', s);
        EXECUTE format('CREATE TABLE %I.billing_periods (LIKE registry.billing_periods INCLUDING ALL)', s);
        EXECUTE format('CREATE TABLE %I.pricing_relationship_events (LIKE registry.pricing_relationship_events INCLUDING ALL)', s);
        EXECUTE format('ALTER TABLE %I.pricing_relationship_events ALTER COLUMN sequence_number SET DEFAULT nextval(%L::regclass)',
            s, format('%I.pricing_relationship_events_sequence_number_seq', s));

        EXECUTE format('ALTER TABLE %I.billing_periods ADD CONSTRAINT billing_periods_pricing_relationship_id_new_fkey
            FOREIGN KEY (pricing_relationship_id) REFERENCES %I.pricing_relationships(id)', s, s);
        EXECUTE format('ALTER TABLE %I.pricing_relationship_events ADD CONSTRAINT pricing_relationship_events_actor_user_id_fkey
            FOREIGN KEY (actor_user_id) REFERENCES %I.users(id)', s, s);
        EXECUTE format('ALTER TABLE %I.pricing_relationship_events ADD CONSTRAINT pricing_relationship_events_relationship_id_fkey
            FOREIGN KEY (relationship_id) REFERENCES %I.pricing_relationships(id) ON DELETE CASCADE', s, s);
        EXECUTE format('ALTER TABLE %I.pricing_relationships ADD CONSTRAINT pricing_relationships_consumer_id_fkey
            FOREIGN KEY (consumer_id) REFERENCES %I.users(id)', s, s);
        EXECUTE format('ALTER TABLE %I.pricing_relationships ADD CONSTRAINT pricing_relationships_pricing_plan_id_fkey
            FOREIGN KEY (pricing_plan_id) REFERENCES %I.pricing_plans(id)', s, s);
        EXECUTE format('ALTER TABLE %I.pricing_relationships ADD CONSTRAINT pricing_relationships_provider_id_fkey
            FOREIGN KEY (provider_id) REFERENCES %I.tenants(id)', s, s);

        -- clone_schema keeps each trigger's function where it found it: public.
        EXECUTE format('CREATE TRIGGER update_pricing_relationships_updated_at BEFORE UPDATE ON %I.pricing_relationships
            FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()', s);
        EXECUTE format('CREATE TRIGGER update_billing_periods_updated_at BEFORE UPDATE ON %I.billing_periods
            FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()', s);
        EXECUTE format('CREATE TRIGGER ensure_pricing_event_sequence BEFORE INSERT ON %I.pricing_relationship_events
            FOR EACH ROW EXECUTE FUNCTION public.ensure_event_sequence()', s);

        EXECUTE format($view$
            CREATE VIEW %1$I.pricing_relationship_current_state AS
            WITH latest_events AS (
                SELECT DISTINCT ON (relationship_id)
                    relationship_id, event_type, event_data, occurred_at, actor_user_id
                FROM %1$I.pricing_relationship_events
                ORDER BY relationship_id, sequence_number DESC
            )
            SELECT pr.id, pr.provider_id, pr.consumer_id, pr.pricing_plan_id, pr.status, pr.metadata,
                   le.event_type AS last_event_type, le.occurred_at AS last_event_at,
                   le.actor_user_id AS last_actor_id, pr.created_at, pr.updated_at
            FROM %1$I.pricing_relationships pr
            LEFT JOIN latest_events le ON le.relationship_id = pr.id
        $view$, s);
    END LOOP;
END $$;

COMMIT;
