-- Revert registry:tenant-scoped-payments from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Revert tenant-scoped-payments: move payment rows back to registry and
-- repoint enrollments.payment_id FKs back to registry.payments.
--
-- CAUTION: revert is only clean while moved rows reference users that are
-- dual-resident (i.e. copied into the tenant schema via copy_user from
-- registry.users).  registry.payments.user_id is NOT NULL REFERENCES
-- registry.users(id), so any payment whose payer exists ONLY in the tenant
-- schema (never copy_user'd) will fail FK validation when moved back into
-- registry.payments.  The transaction aborts loudly with no corruption; those
-- rows need manual handling (copy the user back to registry.users) before
-- revert will succeed.
--
-- The per-tenant payment tables themselves are NOT dropped on revert.
-- Dropping them risks data loss if rows were inserted after the forward
-- migration ran; they are left in place so no data is destroyed.

DO
$$
DECLARE
    s            name;
    fk_conname   name;
    fk_confrelid oid;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        -- Skip if the tenant's payments table does not exist (nothing to revert).
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL;

        -- ------------------------------------------------------------------
        -- Phase 1: Drop the tenant-local enrollments.payment_id FK so rows
        -- can be moved without violating the registry.payments FK.
        -- ------------------------------------------------------------------

        SELECT con.conname, con.confrelid
        INTO fk_conname, fk_confrelid
        FROM pg_constraint con
        JOIN pg_class      src_cl  ON src_cl.oid  = con.conrelid
        JOIN pg_namespace  src_ns  ON src_ns.oid  = src_cl.relnamespace
        JOIN pg_attribute  att     ON att.attrelid = con.conrelid
                                  AND att.attnum   = ANY(con.conkey)
        WHERE con.contype    = 'f'
          AND src_ns.nspname = s
          AND src_cl.relname = 'enrollments'
          AND att.attname    = 'payment_id';

        -- Only drop and re-add if the FK references the tenant's own payments
        -- table (i.e. the forward migration has already run for this tenant).
        IF fk_conname IS NOT NULL
           AND fk_confrelid = to_regclass(format('%I.payments', s)) THEN

            EXECUTE format(
                'ALTER TABLE %I.enrollments DROP CONSTRAINT %I',
                s, fk_conname
            );

            -- ------------------------------------------------------------------
            -- Phase 2: Move payments and payment_items back to registry.
            -- Payments (parent) are inserted into registry first so that the
            -- registry.payment_items FK (payment_id -> registry.payments) is
            -- satisfied when items are inserted.  Deletes follow in reverse
            -- order: items first to avoid cascade surprises, then payments.
            -- ------------------------------------------------------------------

            -- Insert payments into registry (without deleting from tenant yet).
            EXECUTE format(
                $sql$
                INSERT INTO registry.payments
                    (id, user_id, amount, currency, status,
                     stripe_payment_intent_id, stripe_payment_method_id,
                     metadata, created_at, updated_at, completed_at, error_message)
                SELECT id, user_id, amount, currency, status,
                       stripe_payment_intent_id, stripe_payment_method_id,
                       metadata, created_at, updated_at, completed_at, error_message
                FROM %I.payments
                WHERE metadata->>'tenant_slug' = %L
                $sql$,
                s, s
            );

            -- Insert payment_items into registry (payment rows now present).
            EXECUTE format(
                $sql$
                INSERT INTO registry.payment_items
                    (id, payment_id, enrollment_id, description, amount,
                     quantity, metadata, created_at)
                SELECT id, payment_id, enrollment_id, description, amount,
                       quantity, metadata, created_at
                FROM %I.payment_items
                WHERE payment_id IN (
                    SELECT id FROM registry.payments
                    WHERE metadata->>'tenant_slug' = %L
                )
                $sql$,
                s, s
            );

            -- Delete from tenant: items first, then payments.
            EXECUTE format(
                $sql$
                DELETE FROM %I.payment_items
                WHERE payment_id IN (
                    SELECT id FROM %I.payments
                    WHERE metadata->>'tenant_slug' = %L
                )
                $sql$,
                s, s, s
            );
            EXECUTE format(
                $sql$
                DELETE FROM %I.payments
                WHERE metadata->>'tenant_slug' = %L
                $sql$,
                s, s
            );

            -- ------------------------------------------------------------------
            -- Phase 3: Re-add enrollments.payment_id FK pointing back to
            -- registry.payments.
            -- ------------------------------------------------------------------

            EXECUTE format(
                'ALTER TABLE %I.enrollments
                    ADD CONSTRAINT enrollments_payment_id_fkey
                    FOREIGN KEY (payment_id) REFERENCES registry.payments(id)',
                s
            );

            RAISE NOTICE 'Tenant %: reverted enrollments.payment_id FK to registry.payments', s;
        ELSE
            RAISE NOTICE 'Tenant %: enrollments FK already registry-pointing or not found, nothing to revert', s;
        END IF;

    END LOOP;
END
$$ LANGUAGE plpgsql;

COMMIT;
