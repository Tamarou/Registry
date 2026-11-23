-- ABOUTME: Verify the interim tenant-holds-resource table exists and the platform holds operator.
-- ABOUTME: Without the seeded row nobody is served the job queue or the revenue view.

-- Verify registry:operator-right on pg

BEGIN;

SELECT tenant_id, resource
  FROM registry.tenant_resources
 WHERE FALSE;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.tenant_resources
                    WHERE tenant_id = '00000000-0000-0000-0000-000000000000'
                      AND resource = 'operator') THEN
        RAISE EXCEPTION 'the platform tenant does not hold the operator right';
    END IF;
END $$;

ROLLBACK;
