-- ABOUTME: Verify Solo v2 is published (a later Solo version may supersede it), buying payment processing and run rights, with v1 superseded.
-- ABOUTME: Without it signup grants a tenant no workflow run rights.

-- Verify registry:solo-grants-workflow-set on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = md5('solo-grants-workflow-set/version')::uuid
                      AND published_at IS NOT NULL)
    OR NOT EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = '00000000-0000-0000-0003-000000000001' AND superseded_at IS NOT NULL)
    OR NOT EXISTS (SELECT 1 FROM registry.offer_version_resources s JOIN registry.resources r ON r.id = s.resource_id
                    WHERE s.offer_version_id = md5('solo-grants-workflow-set/version')::uuid
                      AND r.name = 'payment processing')
    OR NOT EXISTS (SELECT 1 FROM registry.offer_version_resources s JOIN registry.resources r ON r.id = s.resource_id
                    WHERE s.offer_version_id = md5('solo-grants-workflow-set/version')::uuid
                      AND r.name LIKE 'run:%')
    THEN
        RAISE EXCEPTION 'Solo v2 is not published with payment processing and run rights, or Solo v1 is not superseded';
    END IF;
END $$;

ROLLBACK;
