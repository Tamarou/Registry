-- ABOUTME: Drop the guard holding a tenant to one active platform entitlement to payment processing at a time.
-- ABOUTME: clone_schema gave tenants provisioned since their own no-op copy of the function and trigger.

-- Revert registry:platform-entitlement-one-in-effect from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        IF to_regclass(format('%I.entitlements', s)) IS NOT NULL THEN
            EXECUTE format('DROP TRIGGER IF EXISTS entitlement_one_platform_term ON %I.entitlements', s);
        END IF;
        EXECUTE format('DROP FUNCTION IF EXISTS %I.entitlement_one_platform_term()', s);
    END LOOP;
END $$;

COMMIT;
