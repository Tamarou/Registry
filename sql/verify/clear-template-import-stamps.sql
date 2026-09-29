-- ABOUTME: Verify templates.metadata is the jsonb this change strips a key from, in every schema it walks.
-- ABOUTME: Deliberately does NOT count stamps: the importer re-stamps every row seconds later, by design.

-- Verify registry:clear-template-import-stamps

BEGIN;

-- This used to assert that no template carried imported_sha256, and that was
-- true for exactly as long as it took `registry template import` to run --
-- which docker-entrypoint.sh runs immediately after `sqitch deploy`. So the
-- assertion described a moment, not an invariant, and `sqitch verify` failed on
-- every database anybody had ever imported templates into (#442).
--
-- A check that cannot pass is worse than no check: it trains whoever runs
-- `sqitch verify` to read a failure and shrug. One did hide next to this --
-- pricing-plan-versions' verify was genuinely broken and sat in the same output
-- (fixed in #441).
--
-- Nor is the stamp re-derived here to compare it. The bug this change repairs
-- was two implementations of one hash disagreeing -- Perl hashed the file's
-- BYTES while the value read back was a character string -- and adding a third
-- implementation, in SQL, to check the second would be the same mistake with
-- more steps.
--
-- What is durable is the precondition: the UPDATE strips a key from a jsonb
-- column, in registry and in every tenant schema. If that column stopped being
-- jsonb, this change could not run, and a re-deploy should say so rather than
-- fail inside the DO block with a type error.
DO $$
DECLARE
    s name;
    t text;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.templates', s)) IS NULL;

        SELECT data_type INTO t
          FROM information_schema.columns
         WHERE table_schema = s AND table_name = 'templates'
           AND column_name = 'metadata';

        IF t IS NULL THEN
            RAISE EXCEPTION 'templates.metadata missing in schema %', s;
        END IF;

        IF t <> 'jsonb' THEN
            RAISE EXCEPTION
                'templates.metadata is % in schema %, not jsonb -- this change strips a key from it',
                t, s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
