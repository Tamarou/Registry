-- ABOUTME: Drop pricing_relationships, its event log, the view over it and billing_periods, everywhere.
-- ABOUTME: The tenant's entitlement is now the one record of what a tenant holds (PriceOps step 3).

-- Deploy registry:drop-pricing-relationships to pg
-- requires: payments-offer-version-stamp

BEGIN;

SET client_min_messages = 'warning';

-- Dependants before the table they reference: the view reads the event log and
-- the table, and the event log and billing_periods both hold keys into it.
DROP VIEW IF EXISTS registry.pricing_relationship_current_state;
DROP TABLE IF EXISTS registry.pricing_relationship_events;
DROP TABLE IF EXISTS registry.billing_periods;
DROP TABLE IF EXISTS registry.pricing_relationships;

-- clone_schema copied all four into every tenant schema.  Its sequence copy is
-- not OWNED BY the column, so it does not go with the table and is dropped here.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        EXECUTE format('DROP VIEW IF EXISTS %I.pricing_relationship_current_state', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.pricing_relationship_events', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.billing_periods', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.pricing_relationships', s);
        EXECUTE format('DROP SEQUENCE IF EXISTS %I.pricing_relationship_events_sequence_number_seq', s);
    END LOOP;
END $$;

-- pricing-relationship-events.sql created these in public, unqualified.  They
-- read only the event log, and its trigger -- now gone in every schema -- was
-- ensure_event_sequence's one caller.
DROP FUNCTION IF EXISTS public.get_relationship_state_at(UUID, TIMESTAMP WITH TIME ZONE);
DROP FUNCTION IF EXISTS public.ensure_event_sequence();
DROP FUNCTION IF EXISTS public.get_next_aggregate_version(UUID);

COMMIT;
