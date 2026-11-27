-- ABOUTME: Verify Solo v3 is published (a later Solo version may supersede it), listing the four session workflows' run rights, with v2 superseded.
-- ABOUTME: Without it no tenant may run session-setup, session-checkout, entitlement-decision or makeup-booking.

-- Verify registry:solo-grants-session-workflows on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = md5('solo-grants-session-workflows/version')::uuid
                      AND published_at IS NOT NULL)
    OR NOT EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = md5('solo-grants-workflow-set/version')::uuid AND superseded_at IS NOT NULL)
    OR (SELECT count(*) FROM registry.offer_version_resources s JOIN registry.resources r ON r.id = s.resource_id
         WHERE s.offer_version_id = md5('solo-grants-session-workflows/version')::uuid
           AND r.name IN ('run:session-setup', 'run:session-checkout', 'run:entitlement-decision',
                          'run:makeup-booking')) <> 4
    THEN
        RAISE EXCEPTION 'Solo v3 is not published with the session workflows'' run rights, or Solo v2 is not superseded';
    END IF;
END $$;

ROLLBACK;
