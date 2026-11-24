-- ABOUTME: Verify registry's entitlements carry the guard keeping the platform's self-offers to the platform tenant.
-- ABOUTME: Without it a tenant or person could hold the operator right or the 0% fee.

-- Verify registry:self-offer-guard on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'registry.entitlements'::regclass
                      AND tgname = 'entitlement_holder_is_offerer') THEN
        RAISE EXCEPTION 'registry.entitlements has no entitlement_holder_is_offerer trigger';
    END IF;
END $$;

ROLLBACK;
