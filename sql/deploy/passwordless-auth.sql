-- Deploy registry:passwordless-auth to pg
-- requires: users
-- requires: schema-based-multitennancy

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Make passhash optional for passwordless users
ALTER TABLE users ALTER COLUMN passhash DROP NOT NULL;

-- Add email verification tracking to users
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;

-- Add invite pending flag to users
ALTER TABLE users ADD COLUMN IF NOT EXISTS invite_pending boolean DEFAULT false;

-- Add canonical domain to tenants
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS canonical_domain text;

-- Add magic link expiry configuration to tenants
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS magic_link_expiry_hours integer DEFAULT 24;

-- Passkeys table for WebAuthn credentials
CREATE TABLE IF NOT EXISTS passkeys (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id bytea NOT NULL UNIQUE,
    public_key bytea NOT NULL,
    sign_count bigint NOT NULL DEFAULT 0,
    device_name text,
    created_at timestamptz DEFAULT now(),
    last_used_at timestamptz
);

CREATE INDEX idx_passkeys_user_id ON passkeys(user_id);
CREATE INDEX idx_passkeys_credential_id ON passkeys(credential_id);

-- Magic link tokens for passwordless login and invitations
CREATE TABLE IF NOT EXISTS magic_link_tokens (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    purpose text NOT NULL CHECK (purpose IN ('login', 'invite', 'recovery', 'verify_email')),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_magic_link_tokens_user_id ON magic_link_tokens(user_id);
CREATE INDEX idx_magic_link_tokens_token_hash ON magic_link_tokens(token_hash);

-- API keys for programmatic access
CREATE TABLE IF NOT EXISTS api_keys (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_hash text NOT NULL UNIQUE,
    key_prefix text NOT NULL,
    name text NOT NULL,
    scopes bigint NOT NULL DEFAULT 0,
    expires_at timestamptz,
    last_used_at timestamptz,
    created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_api_keys_user_id ON api_keys(user_id);
CREATE INDEX idx_api_keys_key_hash ON api_keys(key_hash);

-- Propagate to all existing tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        -- Skip tenants that don't have their own schema (e.g. registry-platform)
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        -- Make passhash optional
        EXECUTE format('ALTER TABLE %I.users ALTER COLUMN passhash DROP NOT NULL;', s);

        -- Add user columns
        EXECUTE format('ALTER TABLE %I.users ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;', s);
        EXECUTE format('ALTER TABLE %I.users ADD COLUMN IF NOT EXISTS invite_pending boolean DEFAULT false;', s);

        -- Create passkeys table
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS %I.passkeys (
                id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                user_id uuid NOT NULL REFERENCES %I.users(id) ON DELETE CASCADE,
                credential_id bytea NOT NULL UNIQUE,
                public_key bytea NOT NULL,
                sign_count bigint NOT NULL DEFAULT 0,
                device_name text,
                created_at timestamptz DEFAULT now(),
                last_used_at timestamptz
            );', s, s);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_passkeys_user_id ON %I.passkeys(user_id);', s);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_passkeys_credential_id ON %I.passkeys(credential_id);', s);

        -- Create magic_link_tokens table
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS %I.magic_link_tokens (
                id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                user_id uuid NOT NULL REFERENCES %I.users(id) ON DELETE CASCADE,
                token_hash text NOT NULL UNIQUE,
                purpose text NOT NULL CHECK (purpose IN (''login'', ''invite'', ''recovery'', ''verify_email'')),
                expires_at timestamptz NOT NULL,
                consumed_at timestamptz,
                created_at timestamptz DEFAULT now()
            );', s, s);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_magic_link_tokens_user_id ON %I.magic_link_tokens(user_id);', s);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_magic_link_tokens_token_hash ON %I.magic_link_tokens(token_hash);', s);

        -- Create api_keys table
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS %I.api_keys (
                id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                user_id uuid NOT NULL REFERENCES %I.users(id) ON DELETE CASCADE,
                key_hash text NOT NULL UNIQUE,
                key_prefix text NOT NULL,
                name text NOT NULL,
                scopes bigint NOT NULL DEFAULT 0,
                expires_at timestamptz,
                last_used_at timestamptz,
                created_at timestamptz DEFAULT now()
            );', s, s);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON %I.api_keys(user_id);', s);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_api_keys_key_hash ON %I.api_keys(key_hash);', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
