-- ABOUTME: Verify no schema still carries a TOTAL uniqueness rule on the seat columns.
-- ABOUTME: Checked by shape, not by name -- a tenant's copy is named by Postgres.

-- Verify registry:enrollment-reenrol-after-drop on pg

BEGIN;

DO $$
DECLARE
    s     name;
    found int;
BEGIN
    -- Every check below matches on the COLUMN SET and the predicate, never on a
    -- name. An earlier version of this script looked for
    -- 'enrollments_session_student_type_unique' inside tenant schemas -- the
    -- exact mistake the deploy script documents having fixed, one file over.
    -- clone_schema names a tenant's copy itself, so that lookup returned zero
    -- and verify passed on precisely the databases where the tenant loop had
    -- failed and the money path was still aborting captured settlements.
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug FROM registry.tenants
         WHERE slug != 'registry'
           AND EXISTS ( SELECT 1 FROM information_schema.schemata
                         WHERE schema_name = slug )
    LOOP
        CONTINUE WHEN to_regclass(format('%I.enrollments', s)) IS NULL;

        -- A TOTAL rule on the seat columns, as a constraint OR as a bare unique
        -- index. Both shapes block re-enrolment after a drop; only the
        -- constraint shape was ever searched for.
        SELECT count(*) INTO found
          FROM pg_index i
          JOIN pg_class c   ON c.oid = i.indexrelid
          JOIN pg_class t   ON t.oid = i.indrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE n.nspname = s AND t.relname = 'enrollments'
           AND i.indisunique
           AND i.indpred IS NULL          -- total, not partial
           AND ( SELECT array_agg(a.attname::text ORDER BY a.attname::text)
                   FROM unnest(i.indkey) k
                   JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k )
               = ARRAY['session_id','student_id','student_type'];
        IF found > 0 THEN
            RAISE EXCEPTION
                'schema % still carries a TOTAL uniqueness rule on the seat columns', s;
        END IF;

        -- And the live-only rule must exist, be UNIQUE, and carry a predicate.
        -- Asserting the name alone passed against a non-unique, predicate-less
        -- index -- which the deploy's CREATE UNIQUE INDEX IF NOT EXISTS would
        -- then skip, leaving no rule at all.
        SELECT count(*) INTO found
          FROM pg_index i
          JOIN pg_class t   ON t.oid = i.indrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE n.nspname = s AND t.relname = 'enrollments'
           AND i.indisunique
           AND i.indpred IS NOT NULL
           -- The WHOLE predicate, not a substring of it. Two rounds of this
           -- script tested with LIKE and both were defeatable: '%cancelled%'
           -- accepts the NULL-unsafe <> form, and adding '%IS DISTINCT FROM%'
           -- still accepts
           --     status IS DISTINCT FROM 'cancelled'
           --       AND status IS DISTINCT FROM 'waitlisted'
           -- which contains both substrings, is unique, is partial, carries the
           -- right column set -- and stops covering waitlisted rows, so two of
           -- them can hold one seat. Substring tests on a predicate are a game
           -- the predicate always wins. This is the exact rendering pg_dump
           -- produces, so equality is both stricter and easier to check.
           AND pg_get_expr(i.indpred, i.indrelid)
               = '(status IS DISTINCT FROM ''cancelled''::text)'
           AND ( SELECT array_agg(a.attname::text ORDER BY a.attname::text)
                   FROM unnest(i.indkey) k
                   JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k )
               = ARRAY['session_id','student_id','student_type'];
        IF found = 0 THEN
            RAISE EXCEPTION
                'schema % has no live-only UNIQUE rule on the seat columns', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
