-- ABOUTME: Drop the instalment columns from payments.
-- ABOUTME: Any instalment still owed stops being recorded anywhere; the Stripe schedules keep charging.

-- Revert registry:payments-carry-instalments from pg

BEGIN;

SET client_min_messages = 'warning';

-- Reverting does NOT stop the subscription schedules already at Stripe. They
-- keep billing on their own; what is lost is Registry's record of what is owed
-- and which charge belongs to which set. Cancel the schedules first if that is
-- the intent.
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

        EXECUTE format( 'DROP INDEX IF EXISTS %I.idx_payments_instalment_set', s );
        EXECUTE format( 'DROP INDEX IF EXISTS %I.idx_payments_instalments_due', s );
        EXECUTE format( 'ALTER TABLE %I.payments
            DROP CONSTRAINT IF EXISTS payments_instalment_pair', s );
        EXECUTE format( 'ALTER TABLE %I.payments
            DROP COLUMN IF EXISTS instalment_seq,
            DROP COLUMN IF EXISTS instalment_count,
            DROP COLUMN IF EXISTS due_date,
            DROP COLUMN IF EXISTS stripe_schedule_id', s );
    END LOOP;
END $$;

COMMIT;
