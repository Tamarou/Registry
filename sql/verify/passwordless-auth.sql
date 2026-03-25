-- Verify registry:passwordless-auth on pg

BEGIN;

SET search_path TO registry, public;

-- Verify tables exist by selecting from them
SELECT id, user_id, credential_id, public_key, sign_count, device_name,
       created_at, last_used_at
  FROM passkeys WHERE FALSE;

SELECT id, user_id, token_hash, purpose, expires_at, consumed_at, created_at
  FROM magic_link_tokens WHERE FALSE;

SELECT id, user_id, key_hash, key_prefix, name, scopes, expires_at,
       last_used_at, created_at
  FROM api_keys WHERE FALSE;

-- Verify user columns
SELECT email_verified_at, invite_pending FROM users WHERE FALSE;

-- Verify tenant columns
SELECT canonical_domain, magic_link_expiry_hours FROM tenants WHERE FALSE;

ROLLBACK;
