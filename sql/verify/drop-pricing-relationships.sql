-- ABOUTME: Verify pricing_relationships and its dependants are absent from every schema.
-- ABOUTME: A surviving copy in one tenant schema, or a leftover public function, is the failure this catches.

-- Verify registry:drop-pricing-relationships on pg

BEGIN;

DO $$
DECLARE
    s   name;
    rel text;
BEGIN
    FOR s IN SELECT 'registry' UNION SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        FOREACH rel IN ARRAY ARRAY['pricing_relationship_current_state', 'pricing_relationship_events',
                                   'billing_periods', 'pricing_relationships',
                                   'pricing_relationship_events_sequence_number_seq'] LOOP
            IF to_regclass(format('%I.%I', s, rel)) IS NOT NULL THEN
                RAISE EXCEPTION '%.% still exists', s, rel;
            END IF;
        END LOOP;
    END LOOP;

    IF to_regprocedure('public.ensure_event_sequence()') IS NOT NULL
       OR to_regprocedure('public.get_next_aggregate_version(uuid)') IS NOT NULL
       OR to_regprocedure('public.get_relationship_state_at(uuid, timestamp with time zone)') IS NOT NULL THEN
        RAISE EXCEPTION 'a pricing relationship event function still exists in public';
    END IF;
END $$;

ROLLBACK;
