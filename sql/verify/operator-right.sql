-- ABOUTME: Verify the interim tenant-holds-resource table exists and the platform holds operator.
-- ABOUTME: Without the seeded row nobody is served the job queue or the revenue view.

-- Verify registry:operator-right on pg

BEGIN;

-- operator-right-entitlement moves the row into an entitlement, drops this
-- table and verifies the right there; asserting the table here would make
-- this verify unpassable on any database that has caught up.
DO $$
BEGIN
    -- Nested, so the query naming the table is planned only when it exists.
    IF to_regclass('registry.tenant_resources') IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM registry.tenant_resources
                        WHERE tenant_id = '00000000-0000-0000-0000-000000000000'
                          AND resource = 'operator') THEN
            RAISE EXCEPTION 'the platform tenant does not hold the operator right';
        END IF;
    END IF;
END $$;

ROLLBACK;
