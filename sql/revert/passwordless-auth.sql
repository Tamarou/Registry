-- Revert registry:passwordless-auth from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Revert tenant schemas first
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I.api_keys CASCADE;', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.magic_link_tokens CASCADE;', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.passkeys CASCADE;', s);
        EXECUTE format('ALTER TABLE %I.users DROP COLUMN IF EXISTS invite_pending;', s);
        EXECUTE format('ALTER TABLE %I.users DROP COLUMN IF EXISTS email_verified_at;', s);
        EXECUTE format('UPDATE %I.users SET passhash = '''' WHERE passhash IS NULL;', s);
        EXECUTE format('ALTER TABLE %I.users ALTER COLUMN passhash SET NOT NULL;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Revert registry schema
DROP TABLE IF EXISTS api_keys CASCADE;
DROP TABLE IF EXISTS magic_link_tokens CASCADE;
DROP TABLE IF EXISTS passkeys CASCADE;

ALTER TABLE users DROP COLUMN IF EXISTS invite_pending;
ALTER TABLE users DROP COLUMN IF EXISTS email_verified_at;
UPDATE users SET passhash = '' WHERE passhash IS NULL;
ALTER TABLE users ALTER COLUMN passhash SET NOT NULL;

ALTER TABLE tenants DROP COLUMN IF EXISTS magic_link_expiry_hours;
ALTER TABLE tenants DROP COLUMN IF EXISTS canonical_domain;

COMMIT;
