-- ABOUTME: PriceOps resources (finite or unbounded) and offers with append-only versions.
-- ABOUTME: Built in registry and every tenant schema; clone_schema gives new tenants the same.

-- Deploy registry:priceops-offer-versions to pg
-- requires: tenant-plan-has-rate

BEGIN;

SET client_min_messages = 'warning';

-- One DDL template run for registry first and then every tenant schema, so the
-- copies cannot drift. Foreign keys name the same schema as the table: no
-- foreign key crosses schemas.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        -- Something a tenant controls access to. Finite resources have a
        -- capacity (0 allowed: a sold-out or closed occurrence); unbounded ones
        -- are limited only by policy and must not carry one.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.resources (
                id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                name       text NOT NULL,
                kind       text NOT NULL CHECK (kind IN ('finite', 'unbounded')),
                capacity   integer,
                created_at timestamp with time zone NOT NULL DEFAULT now(),
                CONSTRAINT resources_capacity_matches_kind CHECK (
                    (kind = 'finite' AND capacity IS NOT NULL AND capacity >= 0)
                    OR (kind = 'unbounded' AND capacity IS NULL)
                )
            )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
