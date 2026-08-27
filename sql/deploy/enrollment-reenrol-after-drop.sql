-- ABOUTME: A cancelled enrollment stops occupying its seat, so a dropped child can re-join.
-- ABOUTME: The total constraint made re-enrolment abort a captured settlement, forever.

-- Deploy registry:enrollment-reenrol-after-drop to pg
-- requires: flexible-enrollment-architecture

BEGIN;

SET client_min_messages = 'warning';

-- enrollments_session_student_type_unique was UNIQUE (session_id, student_id,
-- student_type) over EVERY row. Drops do not delete -- they set
-- status = 'cancelled' -- so a child who enrolled, dropped, and re-registered
-- still had a row occupying that slot.
--
-- create_for_payment's conflict arbiter names a different index
-- (enrollments_payment_dedup, scoped to payment_id), and a named arbiter
-- absorbs only its own. So the collision RAISED, inside the settlement
-- transaction, after Stripe had captured: the transaction rolled back, the die
-- released the webhook dedup claim by design, and every redelivery reproduced
-- it identically. Money taken, no enrollment, no waitlist row, no refund owed,
-- nothing to find.
--
-- The constraint's own comment explains it as allowing one logical student in
-- different contexts (different student_type). Blocking re-enrolment after a
-- drop was never its purpose -- children drop and re-join, and the rule should
-- say so rather than every write path working around it.
--
-- No backfill: the constraint being total means no duplicate can already exist,
-- so relaxing it cannot fail on existing data.
ALTER TABLE registry.enrollments
    DROP CONSTRAINT IF EXISTS enrollments_session_student_type_unique;

-- A partial unique INDEX rather than a constraint, because a constraint cannot
-- carry a WHERE clause. It still forbids two live rows for one student in one
-- session, which is the rule that was actually wanted.
CREATE UNIQUE INDEX IF NOT EXISTS enrollments_session_student_type_live
    ON registry.enrollments (session_id, student_id, student_type)
 -- IS DISTINCT FROM, not <>. status is nullable, and NULL <> 'cancelled' is
 -- NULL, so a NULL-status row would be excluded from the index altogether --
 -- turning a rule the old constraint enforced totally into one with a hole.
 WHERE status IS DISTINCT FROM 'cancelled';

-- NOTE ON REACH: sqitch never re-runs a change that is already deployed, so
-- these DROPs only fire on databases deploying this change for the first time.
-- A database that took the earlier draft still carries the table, in registry
-- and in every tenant cloned since, and nothing here will remove it. The table
-- is inert, so on this pre-alpha system that residue is cosmetic and is cleared
-- by hand; it is written down because the alternative is believing it was.
--
-- An earlier draft remembered each tenant's constraint name in a table here, on
-- the theory that restoring everything unnamed would strand a total constraint
-- when flexible-enrollment-architecture is later reverted. Measured, that is
-- false: THAT revert runs ALTER TABLE ... DROP COLUMN student_type, and the
-- constraint goes with the column whatever it is called. The table bought
-- nothing and cost real damage -- clone_schema copies every registry table, so
-- each tenant got its own copy of migration bookkeeping, and this change's
-- revert dropped only the registry one, stranding one per tenant forever.
DROP TABLE IF EXISTS registry.tenant_reenrol_revert_names;

DO $$
DECLARE
    s name;
    c name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        -- Above the enrollments guard on purpose: an earlier draft's bookkeeping
        -- table was cloned into tenants independently of whether that tenant
        -- ever got an enrollments table, so a half-provisioned tenant would
        -- keep its copy forever if this sat below the CONTINUE.
        EXECUTE format(
            'DROP TABLE IF EXISTS %I.tenant_reenrol_revert_names', s);

        -- Schema existence is not table existence: a half-provisioned tenant
        -- would abort the whole migration on the CREATE INDEX below.
        CONTINUE WHEN to_regclass(format('%I.enrollments', s)) IS NULL;

        -- By DISCOVERED name, not the canonical one. clone_schema's
        -- LIKE ... INCLUDING ALL copies the constraint under a name Postgres
        -- generates -- enrollments_session_id_student_id_student_type_key --
        -- so dropping the registry name here is a silent no-op on every tenant
        -- provisioned that way. The bug would have survived untouched in the
        -- schemas that hold the customer money, which is the half of this table
        -- that matters.
        FOR c IN
            SELECT con.conname
              FROM pg_constraint con
              JOIN pg_class rel ON rel.oid = con.conrelid
              JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
             WHERE nsp.nspname = s AND rel.relname = 'enrollments'
               AND con.contype = 'u'
               AND ( SELECT array_agg(att.attname::text ORDER BY att.attname::text)
                       FROM unnest(con.conkey) k
                       JOIN pg_attribute att
                         ON att.attrelid = con.conrelid AND att.attnum = k )
                   = ARRAY['session_id','student_id','student_type']
        LOOP
            EXECUTE format('ALTER TABLE %I.enrollments DROP CONSTRAINT %I', s, c);
        END LOOP;

        EXECUTE format(
            'CREATE UNIQUE INDEX IF NOT EXISTS enrollments_session_student_type_live
                ON %I.enrollments (session_id, student_id, student_type)
             WHERE status IS DISTINCT FROM ''cancelled''', s);
    END LOOP;
END $$;

COMMIT;
