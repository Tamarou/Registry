-- Deploy registry:enrollment-payment-dedup to pg
-- requires: add-payment-to-enrollments

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Idempotency key for the paid enrollment path. The parent-return callback and
-- the payment_intent.succeeded webhook can both finalize the same payment, so a
-- given (session, student, payment) enrollment must exist at most once. Demo
-- enrollments carry no payment_id and are excluded (that path runs once).
CREATE UNIQUE INDEX IF NOT EXISTS enrollments_payment_dedup
    ON enrollments (session_id, student_id, payment_id)
    WHERE payment_id IS NOT NULL;

-- enrollments is cloned into every tenant schema, so propagate the index.
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        EXECUTE format(
            'CREATE UNIQUE INDEX IF NOT EXISTS enrollments_payment_dedup
                ON %I.enrollments (session_id, student_id, payment_id)
                WHERE payment_id IS NOT NULL;',
            s
        );
    END LOOP;
END
$$ LANGUAGE plpgsql;

COMMIT;
