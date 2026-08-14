-- Verify registry:tenant-scoped-payments to pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- For each tenant schema: verify the payment tables exist and that
-- enrollments.payment_id's FK references the tenant's own payments table
-- (not registry.payments).
--
-- With zero tenants (fresh test DB) the loop is a no-op and the verify
-- trivially passes -- that is correct and expected.

DO
$$
DECLARE
    s              name;
    tbl            name;
    fk_ref_schema  name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        -- Verify each payment table exists in the tenant schema.
        FOREACH tbl IN ARRAY ARRAY['payments','payment_items'] LOOP
            IF to_regclass(format('%I.%I', s, tbl)) IS NULL THEN
                RAISE EXCEPTION 'Tenant % is missing payment table %', s, tbl;
            END IF;
        END LOOP;

        -- Verify enrollments.payment_id FK references the tenant's own
        -- payments table (not registry.payments).
        SELECT ref_ns.nspname
        INTO fk_ref_schema
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

        IF fk_ref_schema IS NULL THEN
            RAISE EXCEPTION
                'Tenant %: no FK found on enrollments(payment_id)', s;
        END IF;

        IF fk_ref_schema != s THEN
            RAISE EXCEPTION
                'Tenant %: enrollments.payment_id FK references schema % instead of tenant schema',
                s, fk_ref_schema;
        END IF;
    END LOOP;

    -- Verify no registry.payments rows still belong to a provisioned tenant.
    -- A non-empty result means the migration applied partially (rows moved to the
    -- tenant schema but the registry originals were not deleted), or the migration
    -- was never applied and the verify is catching that.
    IF EXISTS (
        SELECT 1 FROM registry.payments p
        JOIN registry.tenants t ON t.slug = p.metadata->>'tenant_slug'
        WHERE to_regnamespace(quote_ident(t.slug)) IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'tenant-scoped-payments: registry.payments still holds rows belonging to a provisioned tenant';
    END IF;
END
$$ LANGUAGE plpgsql;

COMMIT;
