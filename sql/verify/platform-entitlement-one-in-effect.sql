-- ABOUTME: Verify registry's entitlements carry the guard holding a tenant to one platform entitlement at a time.
-- ABOUTME: Without it two could overlap and the fee would depend on which the resolver picked.

-- Verify registry:platform-entitlement-one-in-effect on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'registry.entitlements'::regclass
                      AND tgname = 'entitlement_one_platform_term') THEN
        RAISE EXCEPTION 'registry.entitlements has no entitlement_one_platform_term trigger';
    END IF;
END $$;

ROLLBACK;
