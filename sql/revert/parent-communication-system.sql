-- Revert registry:parent-communication-system from pg

BEGIN;

-- Drop tables from tenant schemas
DO $$
DECLARE
    tenant_slug text;
BEGIN
    FOR tenant_slug IN 
        SELECT slug FROM registry.tenants WHERE slug != 'registry'
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I.message_recipients CASCADE', tenant_slug);
        EXECUTE format('DROP TABLE IF EXISTS %I.message_templates CASCADE', tenant_slug);
        EXECUTE format('DROP TABLE IF EXISTS %I.messages CASCADE', tenant_slug);
    END LOOP;
END $$;

-- Drop tables from registry schema
DROP TABLE IF EXISTS registry.message_recipients CASCADE;
DROP TABLE IF EXISTS registry.message_templates CASCADE;
DROP TABLE IF EXISTS registry.messages CASCADE;

-- Drop function
DROP FUNCTION IF EXISTS registry.update_updated_at_column() CASCADE;

COMMIT;