-- ABOUTME: Give the capacity-refund obligation typed columns and constrain payments.status.
-- ABOUTME: An operator cannot corrupt an integer with a quoted string, nor invent a status.

-- Deploy registry:payments-typed-obligation to pg
-- requires: refund-amounts-cents

BEGIN;

SET client_min_messages = 'warning';

-- The obligation has lived in unschema'd jsonb since Leg 0: refund_owed_cents,
-- refund_owed_children and refund_manual_review, written by
-- _record_capacity_obligation and read by both settlement callers. Nothing
-- constrains the amount, nothing indexes it, and a second refund overwrites
-- rather than accumulating the total returned.
--
-- refund_seq is what makes the Stripe idempotency key safe. The key was derived
-- from the owed-children list, which unions as the debt grows, so a second
-- attempt travelled under a key Stripe had never seen and refunded the whole
-- accumulated balance again. A counter that only ever increments gives each
-- attempt a key stable for exactly the money it covers.
ALTER TABLE registry.payments
    ADD COLUMN IF NOT EXISTS refund_owed_cents INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS refunded_cents    INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS refund_seq        INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS refund_increments JSONB   NOT NULL DEFAULT '[]'::jsonb;

-- Backfill before the constraints, so a row whose jsonb already violates them
-- fails here with its own data visible rather than at some later write.
UPDATE registry.payments
   SET refund_owed_cents = LEAST(
           COALESCE((metadata->>'refund_owed_cents')::INTEGER, 0), amount_cents),
       refunded_cents = LEAST(
           COALESCE((metadata->>'refund_amount_cents')::INTEGER, 0), amount_cents),
       refund_seq = CASE
           WHEN COALESCE((metadata->>'refund_owed_cents')::INTEGER, 0) > 0 THEN 1
           ELSE 0 END,
       -- An existing unpaid debt becomes increment 1, unsettled, so the
       -- retry path picks it up instead of silently owning an untracked
       -- balance. Its key is refund:capacity:<id>:1, which is NOT the key any
       -- earlier attempt used -- deliberate, since we cannot know whether one
       -- was made. The runbook's list-before-issue is what covers that.
       refund_increments = CASE
           WHEN COALESCE((metadata->>'refund_owed_cents')::INTEGER, 0) > 0
           THEN jsonb_build_array(jsonb_build_object(
                    'seq',      1,
                    'cents',    LEAST((metadata->>'refund_owed_cents')::INTEGER, amount_cents),
                    'children', COALESCE(metadata->'refund_owed_children', '[]'::jsonb),
                    'settled_at', NULL))
           ELSE '[]'::jsonb END
 WHERE metadata ? 'refund_owed_cents' OR metadata ? 'refund_amount_cents';

ALTER TABLE registry.payments
    ADD CONSTRAINT payments_refund_owed_cents_check
        CHECK (refund_owed_cents >= 0 AND refund_owed_cents <= amount_cents),
    ADD CONSTRAINT payments_refunded_cents_check
        CHECK (refunded_cents >= 0 AND refunded_cents <= amount_cents),
    ADD CONSTRAINT payments_refund_seq_check
        CHECK (refund_seq >= 0);

-- Leg 3's ProcessRefunds drives this; today it is what the runbook's finding
-- query scans for.
CREATE INDEX IF NOT EXISTS idx_payments_refund_owed
    ON registry.payments (refund_owed_cents) WHERE refund_owed_cents > 0;

-- The status column has never been constrained. The Leg 0 runbook briefly told
-- operators to write 'refund_failed' -- a value in none of the three
-- classifiers, which both locks the row out of every future refund and invites
-- the next redelivery to re-complete it.
--
-- Seven values, not the five the settlement spec's section 2.1 proposes. That
-- section also collapses partially_refunded into completed-with-refunded_cents
-- and refund_pending into completed-with-refund_owed_cents, which is a code
-- change across both classifiers, the runbook and every fixture. The columns
-- those derivations need land here; the collapse is its own change. A
-- seven-value CHECK stops invented statuses just as well as a five-value one.
ALTER TABLE registry.payments
    ADD CONSTRAINT payments_status_check
        CHECK (status IN ('pending', 'processing', 'completed', 'failed',
                          'refund_pending', 'refunded', 'partially_refunded'));

-- clone_schema copies structure from registry at call time, so new tenants pick
-- this up on their own. Tenants that already exist do not, and payments is
-- tenant-scoped -- an unconstrained tenant copy is where the money actually is.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        EXECUTE format(
            'ALTER TABLE %I.payments
                ADD COLUMN IF NOT EXISTS refund_owed_cents INTEGER NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS refunded_cents    INTEGER NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS refund_seq        INTEGER NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS refund_increments JSONB   NOT NULL DEFAULT ''[]''::jsonb', s);

        EXECUTE format(
            'UPDATE %I.payments
                SET refund_owed_cents = LEAST(
                        COALESCE((metadata->>''refund_owed_cents'')::INTEGER, 0), amount_cents),
                    refunded_cents = LEAST(
                        COALESCE((metadata->>''refund_amount_cents'')::INTEGER, 0), amount_cents),
                    refund_seq = CASE
                        WHEN COALESCE((metadata->>''refund_owed_cents'')::INTEGER, 0) > 0
                        THEN 1 ELSE 0 END
              WHERE metadata ? ''refund_owed_cents'' OR metadata ? ''refund_amount_cents''', s);

        EXECUTE format(
            'ALTER TABLE %I.payments
                ADD CONSTRAINT payments_refund_owed_cents_check
                    CHECK (refund_owed_cents >= 0 AND refund_owed_cents <= amount_cents),
                ADD CONSTRAINT payments_refunded_cents_check
                    CHECK (refunded_cents >= 0 AND refunded_cents <= amount_cents),
                ADD CONSTRAINT payments_refund_seq_check
                    CHECK (refund_seq >= 0),
                ADD CONSTRAINT payments_status_check
                    CHECK (status IN (''pending'', ''processing'', ''completed'', ''failed'',
                                      ''refund_pending'', ''refunded'', ''partially_refunded''))', s);

        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS idx_payments_refund_owed
                ON %I.payments (refund_owed_cents) WHERE refund_owed_cents > 0', s);
    END LOOP;
END $$;

COMMIT;
