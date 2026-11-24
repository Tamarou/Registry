-- ABOUTME: Drop the guard keeping the platform's self-offers to the platform tenant, in registry and every tenant copy.
-- ABOUTME: clone_schema gave tenants provisioned since its own no-op copy of the function and trigger.

-- Revert registry:self-offer-guard from pg

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
            EXECUTE format('DROP TRIGGER IF EXISTS entitlement_holder_is_offerer ON %I.entitlements', s);
        END IF;
        EXECUTE format('DROP FUNCTION IF EXISTS %I.entitlement_holder_is_offerer()', s);
    END LOOP;
END $$;

COMMIT;
