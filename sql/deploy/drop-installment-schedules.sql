-- ABOUTME: Drop the installment schedule tables from registry and every tenant schema.
-- ABOUTME: Nothing reads them: no workflow names the step class and the DAOs are gone.

-- Deploy registry:drop-installment-schedules to pg
-- requires: schedule-amounts-cents
-- requires: tenant-scoped-payments

BEGIN;

SET client_min_messages = 'warning';

-- scheduled_payments references payment_schedules, so it goes first.
DROP TABLE IF EXISTS registry.scheduled_payments;
DROP TABLE IF EXISTS registry.payment_schedules;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        EXECUTE format('DROP TABLE IF EXISTS %I.scheduled_payments', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.payment_schedules', s);
    END LOOP;
END $$;

COMMIT;
