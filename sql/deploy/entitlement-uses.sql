-- ABOUTME: The uses recorded of an entitlement: one row per (entitlement, occurrence), with who marked it and when.
-- ABOUTME: Built in registry and every tenant schema; use is optional attendance, so no row is ever required.

-- Deploy registry:entitlement-uses to pg
-- requires: remove-free-platform-plan

BEGIN;

SET client_min_messages = 'warning';

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

        -- The primary key makes a second mark of the same entitlement at the
        -- same occurrence, or two at once, leave the first.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.entitlement_uses (
                entitlement_id uuid NOT NULL REFERENCES %1$I.entitlements (id),
                occurrence_id  uuid NOT NULL REFERENCES %1$I.resources (id),
                recorded_by    uuid REFERENCES %1$I.users (id),
                recorded_at    timestamp with time zone NOT NULL DEFAULT now(),
                PRIMARY KEY (entitlement_id, occurrence_id)
            )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
