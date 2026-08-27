-- ABOUTME: Verify the total constraint is gone and the live-only rule is in force.
-- ABOUTME: A tenant left on the old rule still aborts captured settlements.

-- Verify registry:enrollment-reenrol-after-drop on pg

BEGIN;

DO $$
DECLARE
    s name;
    found int;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'enrollments_session_student_type_unique'
           AND conrelid = 'registry.enrollments'::regclass
    ) THEN
        RAISE EXCEPTION 'registry.enrollments still carries the total constraint';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
         WHERE schemaname = 'registry'
           AND indexname = 'enrollments_session_student_type_live'
    ) THEN
        RAISE EXCEPTION 'registry.enrollments has no live-only uniqueness rule';
    END IF;

    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'SELECT count(*) FROM pg_constraint
              WHERE conname = ''enrollments_session_student_type_unique''
                AND conrelid = %L::regclass', s || '.enrollments') INTO found;
        IF found > 0 THEN
            RAISE EXCEPTION 'tenant schema % still carries the total constraint', s;
        END IF;

        SELECT count(*) INTO found FROM pg_indexes
         WHERE schemaname = s AND tablename = 'enrollments'
           AND indexdef LIKE '%student_type%' AND indexdef LIKE '%cancelled%';
        IF found = 0 THEN
            RAISE EXCEPTION 'tenant schema % has no live-only uniqueness rule', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
