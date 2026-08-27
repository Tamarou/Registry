-- ABOUTME: Restore the total uniqueness rule on enrollments.
-- ABOUTME: This can fail on data the relaxed rule legitimately permitted.

-- Revert registry:enrollment-reenrol-after-drop from pg

BEGIN;

SET client_min_messages = 'warning';

-- This revert is NOT always possible. Under the partial index a child may have
-- re-enrolled in a session they dropped, which is exactly the point -- and the
-- total constraint refuses that pair. Reverting a database where anyone did so
-- fails with a duplicate key error naming the row.
--
-- That is the correct behaviour: silently deleting or cancelling one of two
-- legitimate enrollments to satisfy a constraint we chose to remove would be
-- worse. Resolve the affected rows by hand first.

DROP INDEX IF EXISTS registry.enrollments_session_student_type_live;

ALTER TABLE registry.enrollments
    ADD CONSTRAINT enrollments_session_student_type_unique
        UNIQUE (session_id, student_id, student_type);

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format('DROP INDEX IF EXISTS %I.enrollments_session_student_type_live', s);

        -- clone_schema's LIKE ... INCLUDING ALL renames a copied index, so a
        -- tenant provisioned after the deploy may carry it under a different
        -- name. sql/revert/refund-amounts-cents.sql is the cautionary example
        -- of a tenant loop that did not mirror its deploy.
        EXECUTE format(
            'DROP INDEX IF EXISTS %I.enrollments_session_student_type_live1', s);

        -- UNNAMED, so Postgres regenerates the same name clone_schema gave it
        -- (enrollments_session_id_student_id_student_type_key). Naming it after
        -- the registry constraint would restore a differently-named object and
        -- the round-trip schema comparison would -- correctly -- call that a
        -- failed revert.
        EXECUTE format(
            'ALTER TABLE %I.enrollments
                ADD UNIQUE (session_id, student_id, student_type)', s);
    END LOOP;
END $$;

COMMIT;
