-- ABOUTME: The specific units of a finite resource a discrete entitlement holds (the seats it occupies).
-- ABOUTME: Built in registry and every tenant schema; grants are counted against capacity under a resource lock.

-- Deploy registry:priceops-entitlement-units to pg
-- requires: priceops-entitlements

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

        -- A unit is numbered 1..capacity within its resource. Whether it is
        -- free is decided under the resource's row lock by the grant, because
        -- it depends on the holding entitlement's period, not on this row.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.entitlement_units (
                entitlement_id uuid NOT NULL REFERENCES %1$I.entitlements (id),
                resource_id    uuid NOT NULL REFERENCES %1$I.resources (id),
                unit           integer NOT NULL
                    CONSTRAINT entitlement_units_unit_check CHECK (unit > 0),
                PRIMARY KEY (resource_id, unit, entitlement_id)
            )
        $f$, s);
    END LOOP;
END $$;

COMMIT;
