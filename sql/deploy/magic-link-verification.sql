-- Deploy registry:magic-link-verification to pg
-- requires: passwordless-auth

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE magic_link_tokens
    ADD COLUMN IF NOT EXISTS verified_at timestamptz;

-- Propagate to all existing tenant schemas
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        EXECUTE format(
            'ALTER TABLE %I.magic_link_tokens ADD COLUMN IF NOT EXISTS verified_at timestamptz;',
            s
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
