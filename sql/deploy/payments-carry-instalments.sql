-- ABOUTME: A payment can be one instalment of several, so the obligation exists in the schema at enrolment.
-- ABOUTME: Reuses payments rather than a schedule table -- two of those were built and dropped unread.

-- Deploy registry:payments-carry-instalments to pg
-- requires: instalments-declared-in-configuration

BEGIN;

SET client_min_messages = 'warning';

-- payment_schedules and scheduled_payments were built, simplified for Stripe,
-- and then dropped by drop-installment-schedules: "Nothing reads them: no
-- workflow names the step class and the DAOs are gone." That is twice a schedule
-- table has been added ahead of anything that would write it.
--
-- payments already has the lifecycle an instalment needs -- pending, processing,
-- completed, failed, all in its existing CHECK -- plus the money columns, the
-- error message, the refund accounting and the Stripe intent id. What it lacks
-- is the ability to say "this is the second of three, due in August". Four
-- columns say it:
--
--   instalment_seq    which one this is, 1..N
--   instalment_count  how many there are, so "2 of 3" needs no join
--   due_date          when it is owed; NULL means now, which is a one-off
--   stripe_schedule_id  the subscription schedule billing the rest of the set
--
-- All NULL for an ordinary single charge, which is what every existing row is.
-- Every instalment of a set is a row from the moment of enrolment, because the
-- obligation exists then: Morgan's outstanding balance is a query over these
-- rather than a call to Stripe per family.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        EXECUTE format( 'ALTER TABLE %I.payments
            ADD COLUMN IF NOT EXISTS instalment_seq     integer,
            ADD COLUMN IF NOT EXISTS instalment_count   integer,
            ADD COLUMN IF NOT EXISTS due_date           date,
            ADD COLUMN IF NOT EXISTS stripe_schedule_id text', s );

        -- Either it is an instalment or it is not. A row carrying a sequence
        -- without a count cannot render "2 of ?", and one carrying a count
        -- without a sequence cannot say which it is.
        EXECUTE format( 'ALTER TABLE %I.payments
            DROP CONSTRAINT IF EXISTS payments_instalment_pair', s );
        EXECUTE format( 'ALTER TABLE %I.payments
            ADD CONSTRAINT payments_instalment_pair CHECK (
                (instalment_seq IS NULL AND instalment_count IS NULL)
                OR (instalment_seq IS NOT NULL AND instalment_count IS NOT NULL
                    AND instalment_seq >= 1 AND instalment_seq <= instalment_count
                    AND instalment_count > 1)
            )', s );

        -- The outstanding-balance query: instalments of one set, in order.
        EXECUTE format( 'CREATE INDEX IF NOT EXISTS idx_payments_instalment_set
            ON %I.payments (stripe_schedule_id, instalment_seq)
            WHERE stripe_schedule_id IS NOT NULL', s );

        -- And what Morgan is owed, across every family.
        EXECUTE format( 'CREATE INDEX IF NOT EXISTS idx_payments_instalments_due
            ON %I.payments (due_date)
            WHERE instalment_seq IS NOT NULL AND status IN (''pending'', ''failed'')', s );
    END LOOP;
END $$;

COMMIT;
