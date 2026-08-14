-- ABOUTME: Verify the installment schedule tables are absent from every schema.
-- ABOUTME: A surviving copy in one tenant schema is the failure this catches.

-- Verify registry:drop-installment-schedules on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    IF to_regclass('registry.payment_schedules') IS NOT NULL THEN
        RAISE EXCEPTION 'registry.payment_schedules still exists';
    END IF;
    IF to_regclass('registry.scheduled_payments') IS NOT NULL THEN
        RAISE EXCEPTION 'registry.scheduled_payments still exists';
    END IF;

    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        IF to_regclass(format('%I.payment_schedules', s)) IS NOT NULL THEN
            RAISE EXCEPTION 'tenant schema %.payment_schedules still exists', s;
        END IF;
        IF to_regclass(format('%I.scheduled_payments', s)) IS NOT NULL THEN
            RAISE EXCEPTION 'tenant schema %.scheduled_payments still exists', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
