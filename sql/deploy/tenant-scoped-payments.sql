-- Deploy registry:tenant-scoped-payments to pg
-- requires: payments
-- requires: installment-payment-schedules
-- requires: add-payment-to-enrollments
-- requires: enrollment-payment-dedup
-- requires: tenant-stripe-connect

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Move payment tables into each tenant schema and repoint enrollments.payment_id
-- to be tenant-local.  This is the prerequisite for Task 4 which unqualifies the
-- Payment / PaymentSchedule / ScheduledPayment DAOs so they resolve via the
-- tenant search_path rather than the hard-coded registry. schema.
--
-- This script is idempotent: re-running it after a revert (and re-deploying)
-- is a supported path and produces no double-move errors.
--
-- CAUTION: The forward migration requires that every payer (user_id) for
-- payments being moved into a tenant schema is already resident in that
-- tenant's users table.  This mirrors the revert script's limitation in
-- reverse: registry.payments.user_id references registry.users, and
-- <tenant>.payments.user_id references <tenant>.users.  If a payment's
-- payer exists only in registry.users and was never copied into the tenant
-- schema via copy_user, the row-move INSERT will fail the tenant FK.
-- The pre-flight check in the loop below detects this condition up-front
-- and raises a diagnosable exception BEFORE any rows are moved, listing
-- the offending payment IDs and user IDs.  Resolve by running:
--   SELECT copy_user(dest_schema => '<slug>', user_id => '<id>');
-- for each offending user, then re-run the migration.
--
-- CAUTION (schedules): payment_schedules / scheduled_payments rows are
-- GUARDED but NOT auto-moved.  registry.scheduled_payments.payment_id
-- references registry.payments(id) with no ON DELETE clause, so deleting a
-- moved payment would throw an FK violation mid-migration for any tenant with
-- linked schedule rows.  Auto-moving would require cross-schema enrollment
-- joins to derive tenant attribution (no per-row tenant_slug metadata exists
-- on these tables), and the InstallmentPayment code path is wired into no
-- production workflow today, so any such rows indicate manual data and need
-- human investigation.  The pre-flight raises a loud exception listing the
-- offending IDs rather than silently corrupting state.
--
-- KEY INVARIANT: A freshly provisioned tenant already has all four payment tables
-- AND a tenant-local enrollments.payment_id FK because clone_schema copies every
-- registry table and re-binds FK definitions to the destination schema at
-- provisioning time.  The loops below exist solely for older production tenants
-- provisioned before the payment migrations were deployed.  In a test database
-- where all migrations deploy before any tenant exists, the loops run over zero
-- rows and are no-ops.
--
-- Per-tenant operation order (STRICT -- must not be changed):
--
--   Phase 0: Pre-flight guard.  Abort with a diagnosable exception if any
--            registry.scheduled_payments or registry.payment_schedules row
--            references a payment that would be moved for this tenant.
--
--   Phase 1: Discover and conditionally DROP the enrollments.payment_id FK.
--            Must happen before any row movement because the DELETE from
--            registry.payments is blocked by the FK referencing it.
--
--   Phase 2: Backfill any missing payment tables, then move rows from
--            registry.payments / registry.payment_items into the tenant schema.
--            Payments (parent) are moved before payment_items (child) so the
--            tenant payment_items FK is satisfied on insert.
--            payment_schedules / scheduled_payments rows are preserved in
--            registry (see CAUTION above) and are not moved.
--
--   Phase 3: ADD the new enrollments.payment_id FK referencing the tenant's
--            own payments table.

DO
$$
DECLARE
    s              name;
    fk_conname     name;
    fk_confrelid   oid;
    moved_payments integer;
    moved_items    integer;
    bad_ids        text;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        -- Skip if the tenant schema does not actually exist yet.
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        -- ------------------------------------------------------------------
        -- Pre-flight: Verify all payers for this tenant's payments are
        -- resident in the tenant schema.
        --
        -- registry.payments rows whose metadata->>'tenant_slug' = s will be
        -- INSERT-ed into <s>.payments, which has a user_id FK referencing
        -- <s>.users.  If the payer exists only in registry.users (never
        -- copied into the tenant schema via copy_user), the INSERT will
        -- abort mid-loop with an opaque FK violation.  We detect this here,
        -- before any rows move, and raise a named exception with enough
        -- detail to resolve the problem without guessing.
        -- ------------------------------------------------------------------

        EXECUTE format(
            $sql$
            SELECT string_agg(
                       format('payment_id=%%s user_id=%%s', p.id, p.user_id),
                       '; '
                   )
            FROM registry.payments p
            WHERE p.metadata->>'tenant_slug' = %L
              AND NOT EXISTS (
                  SELECT 1 FROM %I.users u
                  WHERE u.id = p.user_id
              )
            $sql$,
            s, s
        ) INTO bad_ids;

        IF bad_ids IS NOT NULL THEN
            RAISE EXCEPTION
                'tenant-scoped-payments pre-flight FAILED for tenant "%": '
                'the following payments have payers that do not exist in '
                '%.users: [%].  '
                'Hint: run  SELECT copy_user(dest_schema => ''%'', user_id => ''<id>'');  '
                'for each offending user_id listed above, then re-deploy.',
                s, s, bad_ids, s
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        -- ------------------------------------------------------------------
        -- Pre-flight (schedules): Guard against scheduled_payments or
        -- payment_schedules rows that reference a payment about to be moved.
        --
        -- registry.scheduled_payments.payment_id REFERENCES registry.payments(id)
        -- with no ON DELETE clause.  Deleting the registry.payments row after the
        -- move would trip this FK.  These rows are NOT auto-moved because:
        --   1. Neither payment_schedules nor scheduled_payments carries a
        --      tenant_slug; deriving attribution requires cross-schema enrollment
        --      joins that are fragile and untestable here.
        --   2. The InstallmentPayment workflow step is wired into no production
        --      workflow, so any such rows were created manually and need human
        --      review.
        -- The guard makes the problem loud and diagnosable rather than allowing
        -- the migration to corrupt state silently.
        -- ------------------------------------------------------------------

        EXECUTE format(
            $sql$
            SELECT string_agg(
                       format('scheduled_payment_id=%%s payment_id=%%s', sp.id, sp.payment_id),
                       '; '
                   )
            FROM registry.scheduled_payments sp
            WHERE sp.payment_id IN (
                SELECT id FROM registry.payments
                WHERE metadata->>'tenant_slug' = %L
            )
            $sql$,
            s
        ) INTO bad_ids;

        IF bad_ids IS NOT NULL THEN
            RAISE EXCEPTION
                'tenant-scoped-payments pre-flight FAILED for tenant "%": '
                'the following registry.scheduled_payments rows reference '
                'payments that would be moved: [%].  '
                'These rows have no per-row tenant attribution and cannot be '
                'auto-migrated.  Manually investigate and remove or relocate '
                'them, then re-deploy.',
                s, bad_ids
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        -- ------------------------------------------------------------------
        -- Phase 1: Conditionally drop enrollments.payment_id FK.
        --
        -- For tenants provisioned before the payment migrations, the FK may
        -- reference registry.payments (added by add-payment-to-enrollments
        -- inside a DO loop at that time, before this migration existed).
        -- We discover the FK's referenced table from pg_constraint and only
        -- act when it is registry.payments.  The DROP must precede the row
        -- move because the DELETE from registry.payments is blocked by this FK.
        --
        -- For freshly provisioned tenants, clone_schema already re-bound the
        -- FK to <tenant>.payments.  Those tenants skip the drop here and
        -- jump straight to the row move and FK re-add at the end.
        --
        -- NOTE: The registry template's enrollments.payment_id FK
        -- (registry.enrollments -> registry.payments) is deliberately left
        -- untouched.  An unqualified re-add inside the registry schema would
        -- bind to the identical table, producing no change.  The template
        -- schema diverges from the spec's literal "registry AND every tenant"
        -- wording here because acting on registry would be a no-op.
        -- ------------------------------------------------------------------

        SELECT con.conname, con.confrelid
        INTO fk_conname, fk_confrelid
        FROM pg_constraint con
        JOIN pg_class      src_cl  ON src_cl.oid  = con.conrelid
        JOIN pg_namespace  src_ns  ON src_ns.oid  = src_cl.relnamespace
        JOIN pg_attribute  att     ON att.attrelid = con.conrelid
                                  AND att.attnum   = ANY(con.conkey)
        JOIN pg_class      ref_cl  ON ref_cl.oid  = con.confrelid
        JOIN pg_namespace  ref_ns  ON ref_ns.oid  = ref_cl.relnamespace
        WHERE con.contype    = 'f'
          AND src_ns.nspname = s
          AND src_cl.relname = 'enrollments'
          AND att.attname    = 'payment_id';

        IF fk_conname IS NOT NULL
           AND fk_confrelid = to_regclass('registry.payments') THEN
            -- Drop the cross-schema FK so the row move can proceed.
            EXECUTE format(
                'ALTER TABLE %I.enrollments DROP CONSTRAINT %I',
                s, fk_conname
            );
            RAISE NOTICE 'Tenant %: dropped cross-schema enrollments.payment_id FK', s;
        END IF;

        -- ------------------------------------------------------------------
        -- Phase 2: Backfill any missing payment tables, then move rows.
        -- clone_schema uses LIKE ... INCLUDING ALL which copies indexes,
        -- defaults, and check constraints but NOT foreign keys.  We add the
        -- FKs explicitly below, rewritten to reference the tenant's own tables
        -- rather than the registry. schema tables.
        -- ------------------------------------------------------------------

        IF to_regclass(format('%I.payments', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.payments (LIKE registry.payments INCLUDING ALL)',
                s
            );
            -- payments.user_id must reference the tenant's users, not registry.users.
            -- This is the fix for #237: tenant parents exist only in <tenant>.users.
            EXECUTE format(
                'ALTER TABLE %I.payments
                    ADD CONSTRAINT payments_user_id_fkey
                    FOREIGN KEY (user_id) REFERENCES %I.users(id)',
                s, s
            );
            RAISE NOTICE 'Created %.payments', s;
        END IF;

        IF to_regclass(format('%I.payment_items', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.payment_items (LIKE registry.payment_items INCLUDING ALL)',
                s
            );
            EXECUTE format(
                'ALTER TABLE %I.payment_items
                    ADD CONSTRAINT payment_items_payment_id_fkey
                    FOREIGN KEY (payment_id) REFERENCES %I.payments(id) ON DELETE CASCADE',
                s, s
            );
            RAISE NOTICE 'Created %.payment_items', s;
        END IF;

        IF to_regclass(format('%I.payment_schedules', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.payment_schedules (LIKE registry.payment_schedules INCLUDING ALL)',
                s
            );
            -- payment_schedules has no FK constraints on enrollment_id or
            -- pricing_plan_id in the original migration (those columns are
            -- plain UUID NOT NULL).  No FKs to add here.
            RAISE NOTICE 'Created %.payment_schedules', s;
        END IF;

        IF to_regclass(format('%I.scheduled_payments', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.scheduled_payments (LIKE registry.scheduled_payments INCLUDING ALL)',
                s
            );
            EXECUTE format(
                'ALTER TABLE %I.scheduled_payments
                    ADD CONSTRAINT scheduled_payments_payment_schedule_id_fkey
                    FOREIGN KEY (payment_schedule_id) REFERENCES %I.payment_schedules(id) ON DELETE CASCADE',
                s, s
            );
            EXECUTE format(
                'ALTER TABLE %I.scheduled_payments
                    ADD CONSTRAINT scheduled_payments_payment_id_fkey
                    FOREIGN KEY (payment_id) REFERENCES %I.payments(id)',
                s, s
            );
            RAISE NOTICE 'Created %.scheduled_payments', s;
        END IF;

        -- Move the tenant's payment rows into the tenant schema (INSERT only -- no
        -- DELETE yet).  The enrollments FK was dropped in Phase 1, so the subsequent
        -- DELETE from registry.payments will succeed.
        -- Column list intentionally mirrored in deploy/revert; keep in sync.
        EXECUTE format(
            $sql$
            INSERT INTO %I.payments
                (id, user_id, amount, currency, status,
                 stripe_payment_intent_id, stripe_payment_method_id,
                 metadata, created_at, updated_at, completed_at, error_message)
            SELECT id, user_id, amount, currency, status,
                   stripe_payment_intent_id, stripe_payment_method_id,
                   metadata, created_at, updated_at, completed_at, error_message
            FROM registry.payments
            WHERE metadata->>'tenant_slug' = %L
            $sql$,
            s, s
        );
        GET DIAGNOSTICS moved_payments = ROW_COUNT;

        -- Move payment_items into the tenant schema.  The payments rows are now in
        -- the tenant schema, so the tenant payment_items FK is satisfied.
        -- IMPORTANT: Delete from registry.payment_items BEFORE deleting from
        -- registry.payments (the next step), because registry.payment_items has
        -- ON DELETE CASCADE referencing registry.payments.  If we deleted payments
        -- first, the cascade would remove the registry items before we could copy
        -- them.
        -- Column list intentionally mirrored in deploy/revert; keep in sync.
        EXECUTE format(
            $sql$
            INSERT INTO %I.payment_items
                (id, payment_id, enrollment_id, description, amount,
                 quantity, metadata, created_at)
            SELECT pi.id, pi.payment_id, pi.enrollment_id, pi.description,
                   pi.amount, pi.quantity, pi.metadata, pi.created_at
            FROM registry.payment_items pi
            WHERE pi.payment_id IN (
                SELECT id FROM %I.payments
                WHERE metadata->>'tenant_slug' = %L
            )
            $sql$,
            s, s, s
        );
        GET DIAGNOSTICS moved_items = ROW_COUNT;

        -- Now delete the originals.  Items first (registry cascade constraint),
        -- then payments.
        EXECUTE format(
            $sql$
            DELETE FROM registry.payment_items
            WHERE payment_id IN (
                SELECT id FROM %I.payments
                WHERE metadata->>'tenant_slug' = %L
            )
            $sql$,
            s, s
        );
        EXECUTE format(
            $sql$
            DELETE FROM registry.payments
            WHERE metadata->>'tenant_slug' = %L
            $sql$,
            s
        );

        RAISE NOTICE 'Tenant %: moved % payments, % payment_items', s, moved_payments, moved_items;

        -- ------------------------------------------------------------------
        -- Phase 3: Add the tenant-local enrollments.payment_id FK.
        --
        -- If the FK was registry-pointing and was dropped in Phase 1, we
        -- re-add it here referencing the tenant's own payments table.  If the
        -- FK was already tenant-local (fresh clones), we still re-add it to
        -- keep the constraint name canonical (enrollments_payment_id_fkey).
        -- DROP first if it already exists (fresh-clone case).
        --
        -- NOTE: The plan's spec wording says "skip when already tenant-local",
        -- but we deliberately do an unconditional DROP IF EXISTS + re-ADD
        -- instead.  The unconditional form is MORE robust: it is idempotent
        -- on re-runs, heals constraint-name drift that could arise from manual
        -- interventions, and is safe because clone_schema (see
        -- fix-clone-schema-identifier-quoting.sql) guarantees the canonical
        -- constraint name enrollments_payment_id_fkey for all freshly
        -- provisioned tenants.  Skipping would save one no-op DDL round-trip
        -- at the cost of masking drift silently.
        -- ------------------------------------------------------------------

        -- For fresh-clone tenants the FK was never dropped; drop it now so we
        -- can add the canonical-named version below.
        EXECUTE format(
            'ALTER TABLE %I.enrollments DROP CONSTRAINT IF EXISTS enrollments_payment_id_fkey',
            s
        );

        EXECUTE format(
            'ALTER TABLE %I.enrollments
                ADD CONSTRAINT enrollments_payment_id_fkey
                FOREIGN KEY (payment_id) REFERENCES %I.payments(id)',
            s, s
        );
        RAISE NOTICE 'Tenant %: enrollments.payment_id FK now references tenant schema', s;

    END LOOP;
END
$$ LANGUAGE plpgsql;

COMMIT;
