-- ABOUTME: Remove exactly the bootstrap's seeded resources, offers, versions and registry's entitlements.
-- ABOUTME: Refuses while anything else is stamped with a seeded version, rather than deleting it.

-- Revert registry:bootstrap-platform-offers from pg

BEGIN;

SET client_min_messages = 'warning';

-- Another holder's entitlement is a sale: refuse loudly, never delete it.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.entitlements
                WHERE offer_version_id::text LIKE '00000000-0000-0000-0003-%'
                  AND id::text NOT LIKE '00000000-0000-0000-0004-%') THEN
        RAISE EXCEPTION 'cannot revert bootstrap-platform-offers: an entitlement other '
                        'than the seed''s is held under a seeded offer version';
    END IF;
END $$;

DELETE FROM registry.entitlements WHERE id::text LIKE '00000000-0000-0000-0004-%';

-- Published versions are append-only; the seed's own are the one exception,
-- removed with their plans (by cascade) while the guard is lifted.
ALTER TABLE registry.offer_versions DISABLE TRIGGER offer_versions_immutable;
DELETE FROM registry.offer_versions WHERE id::text LIKE '00000000-0000-0000-0003-%';
ALTER TABLE registry.offer_versions ENABLE TRIGGER offer_versions_immutable;

DELETE FROM registry.offers    WHERE id::text LIKE '00000000-0000-0000-0002-%';
DELETE FROM registry.resources WHERE id::text LIKE '00000000-0000-0000-0001-%';

COMMIT;
