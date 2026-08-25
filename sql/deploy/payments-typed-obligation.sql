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
-- Derived once in the subquery and shared, rather than recomputed per column.
-- Repeating the clamp inline let the two figures disagree: each was clamped to
-- amount_cents independently, so the PAIR could sum past the charge -- and that
-- sum is the runtime headroom rule. record_capacity_obligation refuses every
-- future increment once amount_cents > refund_owed_cents + refunded_cents is
-- false, while the caller loop would meanwhile send Stripe more than the charge.
--
-- refunded_cents is taken first and owed clamped against what is LEFT.
--
-- Note refund_amount_cents was an ASSIGNMENT on the old code path -- the most
-- recent refund, not a cumulative total -- so this under-states what went back
-- for a row refunded more than once. Under-stating is the safe direction: it
-- leaves headroom unclaimed rather than over-claimed.
UPDATE registry.payments p
   SET refunded_cents    = c.refunded,
       refund_owed_cents = c.owed,
       refund_seq        = CASE WHEN c.owed > 0 THEN 1 ELSE 0 END,
       -- An existing unpaid debt becomes increment 1, unsettled, so the retry
       -- path picks it up instead of silently owning an untracked balance. Its
       -- key is refund:capacity:<id>:1, which is NOT the key any earlier attempt
       -- used -- deliberate, since we cannot know whether one was made. The
       -- runbook's list-before-issue is what covers that.
       --
       -- Gated on the CLAMPED figure. Gating on the raw metadata value while
       -- clamping the amount separately produced a zero-cent unsettled
       -- increment on a zero-amount cart, which the workflow-step caller --
       -- which gates on the queue, not the balance -- would POST to Stripe as
       -- amount=0 on every delivery forever.
       refund_increments = CASE WHEN c.owed > 0
           THEN jsonb_build_array(jsonb_build_object(
                    'seq',        1,
                    'cents',      c.owed,
                    'children',   COALESCE(p.metadata->'refund_owed_children', '[]'::jsonb),
                    'settled_at', NULL))
           ELSE '[]'::jsonb END,
       -- Debt the cart cannot absorb is clamped rather than dropped in silence.
       -- main's accumulator was unclamped and could produce one, and the code
       -- path this replaces flags that case for a human; a one-shot pass over
       -- every historical row should be no less careful. Tested against the
       -- headroom left after refunded_cents, not against the whole cart.
       -- Flagged when the cart could not absorb the debt, and also when more
       -- was recorded returned than was ever charged -- a row claiming that is
       -- at least as worth a human's eye.
       metadata = CASE WHEN c.wanted > c.owed OR c.overpaid OR c.wanted < 0
           THEN jsonb_set( COALESCE(p.metadata, '{}'::jsonb), '{refund_manual_review}',
                    COALESCE(p.metadata->'refund_manual_review', '[]'::jsonb)
                    || jsonb_build_array(jsonb_build_object(
                           'reason', CASE
                               WHEN c.wanted < 0 THEN 'backfill floored a negative debt'
                               WHEN c.overpaid  THEN 'backfill clamped a refunded total above the charge'
                               ELSE 'backfill clamped a debt the cart cannot absorb' END,
                           'metadata_owed_cents',   c.wanted,
                           'metadata_refund_cents', COALESCE((p.metadata->>'refund_amount_cents')::INTEGER, 0),
                           'recorded_owed_cents',   c.owed,
                           'recorded_refund_cents', c.refunded)) )
           ELSE p.metadata END
  FROM (
      SELECT id,
             GREATEST( 0, LEAST(
                 COALESCE((metadata->>'refund_amount_cents')::INTEGER, 0),
                 amount_cents ) ) AS refunded,
             COALESCE((metadata->>'refund_owed_cents')::INTEGER, 0) AS wanted,
             ( COALESCE((metadata->>'refund_amount_cents')::INTEGER, 0)
                 > amount_cents ) AS overpaid,
             -- Floored as well as capped. LEAST clamps only the top, and a
             -- negative legacy value -- reachable on main, whose accumulator
             -- was unclamped and whose percentage_discount is unbounded --
             -- violates the CHECK and aborts the deploy naming no row.
             GREATEST( 0, LEAST(
                 COALESCE((metadata->>'refund_owed_cents')::INTEGER, 0),
                 amount_cents - GREATEST( 0, LEAST(
                     COALESCE((metadata->>'refund_amount_cents')::INTEGER, 0),
                     amount_cents ) ) ) ) AS owed
        FROM registry.payments
       WHERE metadata ? 'refund_owed_cents' OR metadata ? 'refund_amount_cents'
  ) c
 WHERE p.id = c.id;

ALTER TABLE registry.payments
    ADD CONSTRAINT payments_refund_owed_cents_check
        CHECK (refund_owed_cents >= 0),
    ADD CONSTRAINT payments_refunded_cents_check
        CHECK (refunded_cents >= 0),
    -- The SUM, not each column against the cart. Two per-column upper bounds
    -- let owed + refunded exceed the charge while both pass individually --
    -- and the sum is the real invariant: it is the headroom rule
    -- record_capacity_obligation applies, and the shape verify treats as fatal.
    -- Runtime could mint it and nothing stopped it.
    ADD CONSTRAINT payments_refund_total_check
        CHECK (refund_owed_cents + refunded_cents <= amount_cents),
    -- refund_increments is the authority for what reaches Stripe, and three
    -- readers call jsonb_array_elements or jsonb_array_length on it -- all of
    -- which RAISE on a non-array. One of those readers runs inside the
    -- settlement transaction, where a raise rolls back a captured charge and
    -- the dedup claim with it, so every retry reproduces it.
    --
    -- The corruption is silent going in: record_capacity_obligation appends
    -- with `||`, and object || object MERGES rather than raising. So the
    -- settlement that poisons the row commits, and the next delivery is the one
    -- that dies. The runbook hands operators raw UPDATEs against this column,
    -- and one deleted `||` produces exactly this.
    ADD CONSTRAINT payments_refund_increments_is_array
        CHECK (jsonb_typeof(refund_increments) = 'array'),
    -- Integer cents, enforced rather than requested. An operator entering
    -- dollars is the likeliest error in a money runbook: the column rounds
    -- 130.50 to 131 while the increment keeps 130.50 verbatim, so the two
    -- disagree and every later (e->>'cents')::int -- including one inside the
    -- settlement transaction -- throws on that row forever. The runbook warns
    -- about it; a warning is not a guard.
    ADD CONSTRAINT payments_refund_increments_cents_integer
        CHECK ( NOT jsonb_path_exists( refund_increments,
                    '$[*].cents ? (@ != @.floor() || @.type() != "number")' ) ),
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
-- Normalise before constraining. This change names 'refund_failed' as the value
-- it expects to find and then adds a CHECK that refuses to deploy if it is
-- there, with no finding query and no way to see which row. A row in that state
-- is one the runbook told an operator to write; refund_pending is where it
-- belongs, and the obligation columns above already carry the amount.
UPDATE registry.payments SET status = 'refund_pending' WHERE status = 'refund_failed';

-- A negative cart aborts payments_refund_total_check naming no row. It is
-- reachable by the mechanism this change already floors for in metadata:
-- PricingPlan's percentage_discount is unbounded, so a plan above 100 yields a
-- negative share. Flagged, not silently zeroed -- a negative charge is a human
-- case, and the amount is preserved in the flag.
UPDATE registry.payments
   SET metadata = jsonb_set( COALESCE(metadata, '{}'::jsonb), '{refund_manual_review}',
           COALESCE(metadata->'refund_manual_review', '[]'::jsonb)
           || jsonb_build_array(jsonb_build_object(
                  'reason', 'migration floored a negative amount_cents',
                  'original_amount_cents', amount_cents)) ),
       amount_cents = 0
 WHERE amount_cents < 0;

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

        -- Mirrors the registry backfill above, clause for clause. This branch
        -- has been wrong twice: once omitting refund_increments entirely, once
        -- omitting the manual-review flag. payments is tenant-scoped, so this
        -- is the copy with the customer money in it.
        EXECUTE format(
            'UPDATE %I.payments p
                SET refunded_cents    = c.refunded,
                    refund_owed_cents = c.owed,
                    refund_seq        = CASE WHEN c.owed > 0 THEN 1 ELSE 0 END,
                    refund_increments = CASE WHEN c.owed > 0
                        THEN jsonb_build_array(jsonb_build_object(
                                 ''seq'',        1,
                                 ''cents'',      c.owed,
                                 ''children'',   COALESCE(p.metadata->''refund_owed_children'', ''[]''::jsonb),
                                 ''settled_at'', NULL))
                        ELSE ''[]''::jsonb END,
                    metadata = CASE WHEN c.wanted > c.owed OR c.overpaid OR c.wanted < 0
                        THEN jsonb_set( COALESCE(p.metadata, ''{}''::jsonb), ''{refund_manual_review}'',
                                 COALESCE(p.metadata->''refund_manual_review'', ''[]''::jsonb)
                                 || jsonb_build_array(jsonb_build_object(
                                        ''reason'', CASE
                                            WHEN c.wanted < 0 THEN ''backfill floored a negative debt''
                                            WHEN c.overpaid  THEN ''backfill clamped a refunded total above the charge''
                                            ELSE ''backfill clamped a debt the cart cannot absorb'' END,
                                        ''metadata_owed_cents'',   c.wanted,
                                        ''metadata_refund_cents'', COALESCE((p.metadata->>''refund_amount_cents'')::INTEGER, 0),
                                        ''recorded_owed_cents'',   c.owed,
                                        ''recorded_refund_cents'', c.refunded)) )
                        ELSE p.metadata END
               FROM (
                   SELECT id,
                          GREATEST( 0, LEAST(
                              COALESCE((metadata->>''refund_amount_cents'')::INTEGER, 0),
                              amount_cents ) ) AS refunded,
                          COALESCE((metadata->>''refund_owed_cents'')::INTEGER, 0) AS wanted,
                          ( COALESCE((metadata->>''refund_amount_cents'')::INTEGER, 0)
                              > amount_cents ) AS overpaid,
                          GREATEST( 0, LEAST(
                              COALESCE((metadata->>''refund_owed_cents'')::INTEGER, 0),
                              amount_cents - GREATEST( 0, LEAST(
                                  COALESCE((metadata->>''refund_amount_cents'')::INTEGER, 0),
                                  amount_cents ) ) ) ) AS owed
                     FROM %I.payments
                    WHERE metadata ? ''refund_owed_cents'' OR metadata ? ''refund_amount_cents''
               ) c
              WHERE p.id = c.id', s, s);

        EXECUTE format(
            'UPDATE %I.payments SET status = ''refund_pending''
              WHERE status = ''refund_failed''', s);

        EXECUTE format(
            'UPDATE %I.payments
                SET metadata = jsonb_set( COALESCE(metadata, ''{}''::jsonb), ''{refund_manual_review}'',
                        COALESCE(metadata->''refund_manual_review'', ''[]''::jsonb)
                        || jsonb_build_array(jsonb_build_object(
                               ''reason'', ''migration floored a negative amount_cents'',
                               ''original_amount_cents'', amount_cents)) ),
                    amount_cents = 0
              WHERE amount_cents < 0', s);

        EXECUTE format(
            'ALTER TABLE %I.payments
                ADD CONSTRAINT payments_refund_owed_cents_check
                    CHECK (refund_owed_cents >= 0),
                ADD CONSTRAINT payments_refunded_cents_check
                    CHECK (refunded_cents >= 0),
                ADD CONSTRAINT payments_refund_total_check
                    CHECK (refund_owed_cents + refunded_cents <= amount_cents),
                ADD CONSTRAINT payments_refund_increments_is_array
                    CHECK (jsonb_typeof(refund_increments) = ''array''),
                ADD CONSTRAINT payments_refund_increments_cents_integer
                    CHECK ( NOT jsonb_path_exists( refund_increments,
                                ''$[*].cents ? (@ != @.floor() || @.type() != "number")'' ) ),
                ADD CONSTRAINT payments_refund_seq_check
                    CHECK (refund_seq >= 0),
                ADD CONSTRAINT payments_status_check
                    CHECK (status IN (''pending'', ''processing'', ''completed'', ''failed'',
                                      ''refund_pending'', ''refunded'', ''partially_refunded''))', s);

        -- Skipped when the tenant already has an equivalent index under any
        -- name. clone_schema's LIKE ... INCLUDING ALL copies this index but
        -- renames it to payments_refund_owed_cents_idx, so IF NOT EXISTS --
        -- which matches on name only -- would create a second, duplicate index
        -- on tenants provisioned that way, and the revert's DROP of the
        -- hardcoded name would then be a silent no-op.
        IF NOT EXISTS (
            SELECT 1 FROM pg_indexes
             WHERE schemaname = s AND tablename = 'payments'
               AND indexdef LIKE '%refund_owed_cents%WHERE%'
        ) THEN
            EXECUTE format(
                'CREATE INDEX idx_payments_refund_owed
                    ON %I.payments (refund_owed_cents) WHERE refund_owed_cents > 0', s);
        END IF;
    END LOOP;
END $$;

COMMIT;
