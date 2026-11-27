-- ABOUTME: A refund or change whose policy needs an admin's approval: the computed outcome, waiting for one decision.
-- ABOUTME: Built in registry and every tenant schema; clone_schema gives new tenants the same.

-- Deploy registry:entitlement-requests to pg
-- requires: instalment-payment-plans

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.entitlements', s)) IS NULL;

        -- Decided means decided_by and decided_at are set; pending means neither is.
        EXECUTE format($f$
            CREATE TABLE %1$I.entitlement_requests (
                id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                entitlement_id  uuid NOT NULL REFERENCES %1$I.entitlements (id),
                kind            text NOT NULL CHECK (kind IN ('refund', 'change')),
                workflow_run_id uuid NOT NULL UNIQUE REFERENCES %1$I.workflow_runs (id),
                outcome         jsonb NOT NULL,
                state           text NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending', 'approved', 'declined')),
                requested_by    uuid NOT NULL REFERENCES %1$I.users (id),
                decided_by      uuid REFERENCES %1$I.users (id),
                decided_at      timestamp with time zone,
                note            text,
                created_at      timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
                CONSTRAINT entitlement_requests_decided CHECK (
                    num_nonnulls(decided_by, decided_at) = CASE WHEN state = 'pending' THEN 0 ELSE 2 END
                )
            )
        $f$, s);
        -- Indexes take default names, as clone_schema's LIKE ... INCLUDING ALL gives.
        EXECUTE format('CREATE INDEX ON %I.entitlement_requests (entitlement_id)', s);
        EXECUTE format('CREATE INDEX ON %I.entitlement_requests (created_at, id) WHERE state = ''pending''', s);
    END LOOP;
END $$;

COMMIT;
