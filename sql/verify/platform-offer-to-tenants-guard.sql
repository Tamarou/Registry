-- ABOUTME: Verify registry's offer versions carry the guard keeping a current platform offer to tenants.
-- ABOUTME: Without it a new Solo version could leave signup with no offer to grant.

-- Verify registry:platform-offer-to-tenants-guard on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'registry.offer_versions'::regclass
                      AND tgname = 'offer_versions_keep_platform_offer'
                      AND tgdeferrable AND tginitdeferred) THEN
        RAISE EXCEPTION 'registry.offer_versions has no deferred offer_versions_keep_platform_offer trigger';
    END IF;
END $$;

ROLLBACK;
