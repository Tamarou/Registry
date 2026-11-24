-- ABOUTME: Verify registry's resources carry the guard keeping the platform offer's resource name.
-- ABOUTME: Without it a rename could leave signup with no platform offer to grant.

-- Verify registry:platform-offer-resource-keeps-name on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'registry.resources'::regclass
                      AND tgname = 'resources_keep_platform_offer_name') THEN
        RAISE EXCEPTION 'registry.resources has no resources_keep_platform_offer_name trigger';
    END IF;
END $$;

ROLLBACK;
