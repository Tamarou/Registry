-- ABOUTME: Verify the bootstrap's Solo v1 is published.
-- ABOUTME: Without it signup has nothing to offer tenants.

-- Verify registry:bootstrap-platform-offers on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.offer_versions
                    WHERE id = '00000000-0000-0000-0003-000000000001'
                      AND published_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Solo v1 is not published';
    END IF;
END $$;

ROLLBACK;
