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
    s    name;
    ix   name;
    orig name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        CONTINUE WHEN to_regclass(format('%I.enrollments', s)) IS NULL;

        -- By DISCOVERY, not by name. An earlier version guessed
        -- 'enrollments_session_student_type_live1' on the theory that
        -- clone_schema suffixes a digit. It does not -- LIKE ... INCLUDING ALL
        -- discards the source name entirely and lets Postgres pick
        -- (enrollments_session_id_student_id_student_type_idx, measured). Both
        -- guesses missed, so a tenant cloned after the deploy kept the partial
        -- index forever while the revert reported success.
        FOR ix IN
            SELECT c.relname
              FROM pg_index i
              JOIN pg_class c   ON c.oid = i.indexrelid
              JOIN pg_class t   ON t.oid = i.indrelid
              JOIN pg_namespace n ON n.oid = t.relnamespace
             WHERE n.nspname = s AND t.relname = 'enrollments'
               AND i.indisunique AND i.indpred IS NOT NULL
               AND pg_get_expr(i.indpred, i.indrelid) LIKE '%cancelled%'
               AND ( SELECT array_agg(a.attname::text ORDER BY a.attname::text)
                       FROM unnest(i.indkey) k
                       JOIN pg_attribute a
                         ON a.attrelid = i.indrelid AND a.attnum = k )
                   = ARRAY['session_id','student_id','student_type']
        LOOP
            EXECUTE format('DROP INDEX %I.%I', s, ix);
        END LOOP;

        -- Restore under the name this tenant actually had. A tenant provisioned
        -- by flexible-enrollment-architecture's own loop carries the registry
        -- name, and THAT change's revert drops it by that name -- so restoring
        -- everything unnamed left a total constraint stranded on enrollments
        -- when the earlier change was later reverted. A clone-provisioned
        -- tenant has the generated name, which an unnamed ADD UNIQUE
        -- reproduces.
        SELECT conname INTO orig
          FROM pg_constraint
         WHERE conname = 'enrollments_session_student_type_unique'
           AND conrelid = format('%I.enrollments', s)::regclass;

        IF EXISTS ( SELECT 1 FROM registry.tenant_reenrol_revert_names
                     WHERE schema_name = s )
        THEN
            SELECT constraint_name INTO orig
              FROM registry.tenant_reenrol_revert_names WHERE schema_name = s;
            EXECUTE format(
                'ALTER TABLE %I.enrollments ADD CONSTRAINT %I
                     UNIQUE (session_id, student_id, student_type)', s, orig);
        ELSE
            EXECUTE format(
                'ALTER TABLE %I.enrollments
                    ADD UNIQUE (session_id, student_id, student_type)', s);
        END IF;
    END LOOP;
END $$;

DROP TABLE IF EXISTS registry.tenant_reenrol_revert_names;

COMMIT;
