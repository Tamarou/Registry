-- Revert registry:enrollment-payment-dedup from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP INDEX IF EXISTS enrollments_payment_dedup;

DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        EXECUTE format('DROP INDEX IF EXISTS %I.enrollments_payment_dedup;', s);
    END LOOP;
END
$$ LANGUAGE plpgsql;

COMMIT;
