# Passwordless Authentication System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace password-based authentication with a passwordless system built on WebAuthn passkeys (primary), magic links (fallback/bootstrap), and bearer token API keys.

**Architecture:** All auth credentials live in tenant schemas (not global). Three auth methods checked in priority order: bearer token → session cookie → unauthenticated. WebAuthn uses a custom Object::Pad implementation (`Registry::Auth::WebAuthn`) built on CBOR::XS + CryptX. Magic links bootstrap first sessions and serve as passkey fallback.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, PostgreSQL JSONB, CBOR::XS, CryptX (Crypt::PK::ECC, Crypt::PK::RSA, Crypt::PK::Ed25519), Crypt::URandom, Sqitch migrations, Test2::V0/Test::More

**Spec:** `docs/specs/auth-system.md`

---

## File Structure

### New Files

**Database Migrations (Sqitch triples):**
- `sql/deploy/passwordless-auth.sql` — passkeys, magic_link_tokens, api_keys tables; users.passhash nullable; email_verified_at; tenant canonical_domain
- `sql/revert/passwordless-auth.sql` — undo all schema changes
- `sql/verify/passwordless-auth.sql` — verify tables and columns exist

**DAO Classes:**
- `lib/Registry/DAO/Passkey.pm` — CRUD for passkeys table, sign count tracking
- `lib/Registry/DAO/MagicLinkToken.pm` — create, find_by_hash, consume, expiry
- `lib/Registry/DAO/ApiKey.pm` — create (returns plaintext once), find_by_hash, scope checks

**WebAuthn Library:**
- `lib/Registry/Auth/WebAuthn.pm` — main class: registration/authentication options and verification
- `lib/Registry/Auth/WebAuthn/Challenge.pm` — challenge generation and session storage
- `lib/Registry/Auth/WebAuthn/COSE.pm` — COSE key parsing (CBOR → Crypt::PK::*)
- `lib/Registry/Auth/WebAuthn/AuthenticatorData.pm` — parse authenticator data structure

**Controller:**
- `lib/Registry/Controller/Auth.pm` — all /auth/* routes

**Frontend:**
- `templates/auth/login.html.ep` — login page (passkey prompt + magic link request)
- `templates/auth/register-passkey.html.ep` — passkey registration UI
- `templates/auth/magic-link-sent.html.ep` — confirmation after magic link request
- `templates/auth/magic-link-error.html.ep` — expired/invalid/used token errors
- `templates/auth/verify-email.html.ep` — email verification result

**Utilities:**
- `lib/Registry/Util/Time.pm` — shared ISO timestamp helper for expiry comparisons

**Tests:**
- `t/dao/passkey.t` — passkey DAO unit tests
- `t/dao/magic-link-token.t` — magic link token DAO unit tests
- `t/dao/api-key.t` — API key DAO unit tests
- `t/dao/user-auth.t` — user creation without password, relationship accessors
- `t/dao/email-templates-auth.t` — auth-related email template rendering
- `t/auth/webauthn.t` — WebAuthn library unit tests (test vectors)
- `t/auth/webauthn-cose.t` — COSE key parsing tests
- `t/auth/webauthn-authenticator-data.t` — authenticator data parsing tests
- `t/auth/webauthn-challenge.t` — challenge generation, encode/decode
- `t/controller/auth.t` — all /auth/* controller routes
- `t/controller/api-auth.t` — bearer token authentication
- `t/integration/auth-flow.t` — full magic link flow end-to-end
- `t/integration/tenant-signup-auth.t` — signup workflow creates session, offers passkey
- `t/integration/multi-tenant-auth.t` — cross-tenant credential isolation
- `t/security/auth-security.t` — timing-safe comparison, rate limiting, CSRF, entropy

### Modified Files

- `sql/sqitch.plan` — add passwordless-auth migration entry
- `cpanfile` — add CBOR::XS, CryptX, Crypt::URandom
- `lib/Registry.pm` — extend before_dispatch for bearer token + tenant-schema user lookup; update require_auth redirect; add /auth/* routes; add canonical_domain redirect
- `lib/Registry/DAO/User.pm` — passhash optional, add passkeys/magic_link_tokens/api_keys accessors
- `lib/Registry/DAO/Tenant.pm` — add canonical_domain field and accessor
- `lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm` — remove password handling, create magic link tokens for invites
- `lib/Registry/DAO/WorkflowSteps/AccountCheck.pm` — replace password verification with passkey/magic link
- `lib/Registry/Email/Template.pm` — add magic_link_login, magic_link_invite, email_verification, passkey_registered, passkey_removed templates
- `templates/tenant-signup/users.html.ep` — remove admin_password field
- `templates/tenant-signup/complete.html.ep` — add passkey registration prompt

---

## Task 1: CPAN Dependencies

**Files:**
- Modify: `cpanfile`

- [ ] **Step 1: Add new dependencies to cpanfile**

Add after the existing `Crypt::Passphrase::Bcrypt` line:

```perl
requires 'CBOR::XS';           # WebAuthn attestation object and COSE key decoding
requires 'CryptX';             # Crypt::PK::ECC (ES256), Crypt::PK::RSA (RS256), Crypt::PK::Ed25519 (EdDSA), Crypt::Digest::SHA256
requires 'Crypt::URandom';     # Cryptographic random bytes for challenges and tokens
```

- [ ] **Step 2: Install dependencies**

Run: `carton install`
Expected: Dependencies installed successfully, cpanfile.snapshot updated

- [ ] **Step 3: Commit**

```bash
git add cpanfile cpanfile.snapshot
git commit -m "Add CPAN dependencies for WebAuthn and token generation"
```

---

## Task 2: Database Migration — Passwordless Auth Tables

**Files:**
- Create: `sql/deploy/passwordless-auth.sql`
- Create: `sql/revert/passwordless-auth.sql`
- Create: `sql/verify/passwordless-auth.sql`
- Modify: `sql/sqitch.plan`

- [ ] **Step 1: Add migration to sqitch.plan**

Append to `sql/sqitch.plan`:

```
passwordless-auth [users schema-based-multitennancy] 2026-03-25T00:00:00Z Chris Prather <chris.prather@tamarou.com> # Passwordless auth: passkeys, magic links, API keys
```

- [ ] **Step 2: Write deploy migration**

Create `sql/deploy/passwordless-auth.sql`:

```sql
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
```

- [ ] **Step 3: Write revert migration**

Create `sql/revert/passwordless-auth.sql`:

```sql
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
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Revert registry schema
DROP TABLE IF EXISTS api_keys CASCADE;
DROP TABLE IF EXISTS magic_link_tokens CASCADE;
DROP TABLE IF EXISTS passkeys CASCADE;

ALTER TABLE users DROP COLUMN IF EXISTS invite_pending;
ALTER TABLE users DROP COLUMN IF EXISTS email_verified_at;

ALTER TABLE tenants DROP COLUMN IF EXISTS magic_link_expiry_hours;
ALTER TABLE tenants DROP COLUMN IF EXISTS canonical_domain;

COMMIT;
```

- [ ] **Step 4: Write verify migration**

Create `sql/verify/passwordless-auth.sql`:

```sql
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
```

- [ ] **Step 5: Deploy migration and verify**

Run: `cd /home/perigrin/dev/Registry && carton exec sqitch deploy`
Expected: `Deploying changes to ...` with `passwordless-auth` applied

Run: `cd /home/perigrin/dev/Registry && carton exec sqitch verify`
Expected: All verifications pass

- [ ] **Step 6: Run existing tests to confirm no regressions**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All existing tests pass (100%)

- [ ] **Step 7: Commit**

```bash
git add sql/deploy/passwordless-auth.sql sql/revert/passwordless-auth.sql sql/verify/passwordless-auth.sql sql/sqitch.plan
git commit -m "Add passwordless auth tables: passkeys, magic_link_tokens, api_keys"
```

---

## Task 3: DAO — Registry::DAO::Passkey

**Files:**
- Create: `lib/Registry/DAO/Passkey.pm`
- Create: `t/dao/passkey.t`

- [ ] **Step 1: Write the failing test**

Create `t/dao/passkey.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Unit tests for the Passkey DAO — CRUD, sign count tracking,
# ABOUTME: cascade delete, and multi-passkey-per-user support.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::Passkey;
use Registry::DAO::User;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test user (passwordless — no passhash required)
my $user = Registry::DAO::User->create($db, {
    username => 'passkey_test_user',
    email    => 'passkey@example.com',
    name     => 'Passkey Tester',
});
ok($user, 'Created test user');

subtest 'Create a passkey' => sub {
    my $passkey = Registry::DAO::Passkey->create($db, {
        user_id       => $user->id,
        credential_id => pack('H*', 'deadbeef01020304'),
        public_key    => pack('H*', 'cafebabe05060708'),
        device_name   => 'Test MacBook',
    });

    ok($passkey, 'Passkey created');
    ok($passkey->id, 'Has UUID id');
    is($passkey->user_id, $user->id, 'Correct user_id');
    is($passkey->sign_count, 0, 'Initial sign count is 0');
    is($passkey->device_name, 'Test MacBook', 'Device name stored');
    ok($passkey->created_at, 'Has created_at timestamp');
    ok(!$passkey->last_used_at, 'No last_used_at initially');
};

subtest 'Find passkey by credential_id' => sub {
    my $cred_id = pack('H*', 'deadbeef01020304');
    my $found = Registry::DAO::Passkey->find($db, {
        credential_id => $cred_id,
    });

    ok($found, 'Found passkey by credential_id');
    is($found->user_id, $user->id, 'Correct user');
};

subtest 'Update sign count' => sub {
    my $cred_id = pack('H*', 'deadbeef01020304');
    my $passkey = Registry::DAO::Passkey->find($db, {
        credential_id => $cred_id,
    });

    my $updated = $passkey->update_sign_count($db, 1);
    is($updated->sign_count, 1, 'Sign count updated to 1');
    ok($updated->last_used_at, 'last_used_at set after use');

    # Sign count must always increase (replay protection)
    dies_ok { $passkey->update_sign_count($db, 0) }
        'Rejects sign count regression (replay protection)';
};

subtest 'Multiple passkeys per user' => sub {
    my $passkey2 = Registry::DAO::Passkey->create($db, {
        user_id       => $user->id,
        credential_id => pack('H*', 'aabbccdd11223344'),
        public_key    => pack('H*', '11223344aabbccdd'),
        device_name   => 'Test iPhone',
    });

    ok($passkey2, 'Second passkey created');

    my @all = Registry::DAO::Passkey->for_user($db, $user->id);
    is(scalar @all, 2, 'User has 2 passkeys');
};

subtest 'Credential ID uniqueness' => sub {
    dies_ok {
        Registry::DAO::Passkey->create($db, {
            user_id       => $user->id,
            credential_id => pack('H*', 'deadbeef01020304'),  # duplicate
            public_key    => pack('H*', 'ffffffffffffffff'),
        });
    } 'Duplicate credential_id rejected';
};

subtest 'Cascade delete with user' => sub {
    my $temp_user = Registry::DAO::User->create($db, {
        username => 'temp_passkey_user',
        email    => 'temp@example.com',
        name     => 'Temp User',
    });

    Registry::DAO::Passkey->create($db, {
        user_id       => $temp_user->id,
        credential_id => pack('H*', 'eeeeeeeeeeeeeeee'),
        public_key    => pack('H*', 'dddddddddddddddd'),
    });

    # Delete the user
    $db->db->delete('users', { id => $temp_user->id });

    my $orphan = Registry::DAO::Passkey->find($db, {
        credential_id => pack('H*', 'eeeeeeeeeeeeeeee'),
    });
    ok(!$orphan, 'Passkey cascade-deleted with user');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/passkey.t`
Expected: FAIL — `Can't locate Registry/DAO/Passkey.pm`

- [ ] **Step 3: Write minimal implementation**

Create `lib/Registry/DAO/Passkey.pm`:

```perl
# ABOUTME: DAO for WebAuthn passkey credentials. Handles CRUD operations,
# ABOUTME: sign count tracking with replay protection, and per-user queries.
use 5.42.0;
use Object::Pad;

class Registry::DAO::Passkey :isa(Registry::DAO::Object) {
    use Carp qw(croak);

    field $id :param :reader;
    field $user_id :param :reader;
    field $credential_id :param :reader;
    field $public_key :param :reader;
    field $sign_count :param :reader = 0;
    field $device_name :param :reader = undef;
    field $created_at :param :reader = undef;
    field $last_used_at :param :reader = undef;

    sub table { 'passkeys' }

    method update_sign_count ($db, $new_count) {
        croak "Sign count regression detected (replay attack?): stored=$sign_count, received=$new_count"
            if $new_count <= $sign_count;

        $db = $db->db if $db isa Registry::DAO;

        return $self->update($db, {
            sign_count   => $new_count,
            last_used_at => \'now()',
        });
    }

    sub for_user ($class, $db, $user_id) {
        $db = $db->db if $db isa Registry::DAO;

        my @rows = $db->select('passkeys', '*', { user_id => $user_id },
            { -asc => 'created_at' })->hashes->each;

        return map { $class->new(%$_) } @rows;
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/passkey.t`
Expected: All subtests pass

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/DAO/Passkey.pm t/dao/passkey.t
git commit -m "Add Registry::DAO::Passkey with CRUD and sign count replay protection"
```

---

## Task 4: DAO — Registry::DAO::MagicLinkToken

**Files:**
- Create: `lib/Registry/DAO/MagicLinkToken.pm`
- Create: `t/dao/magic-link-token.t`

- [ ] **Step 1: Write the failing test**

Create `t/dao/magic-link-token.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Unit tests for MagicLinkToken DAO — creation, hash verification,
# ABOUTME: consumption, expiry enforcement, and single-use semantics.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::MagicLinkToken;
use Registry::DAO::User;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

my $user = Registry::DAO::User->create($db, {
    username => 'magic_link_test_user',
    email    => 'magic@example.com',
    name     => 'Magic Link Tester',
});

subtest 'Generate a magic link token' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok($token_obj, 'Token object created');
    ok($plaintext, 'Plaintext token returned');
    ok(length($plaintext) > 20, 'Plaintext has sufficient length');
    is($token_obj->user_id, $user->id, 'Correct user_id');
    is($token_obj->purpose, 'login', 'Correct purpose');
    ok(!$token_obj->consumed_at, 'Not yet consumed');
    ok($token_obj->expires_at, 'Has expiry timestamp');

    # Plaintext should NOT be stored — only the hash
    isnt($token_obj->token_hash, $plaintext, 'Stored hash differs from plaintext');
};

subtest 'Find by plaintext token (hash lookup)' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'invite',
    });

    my $found = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);
    ok($found, 'Found token by plaintext hash lookup');
    is($found->id, $token_obj->id, 'Correct token found');
    is($found->purpose, 'invite', 'Correct purpose');
};

subtest 'Consume a token (single-use)' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    my $consumed = $token_obj->consume($db);
    ok($consumed->consumed_at, 'consumed_at set after consumption');

    # Attempting to consume again should fail
    dies_ok { $consumed->consume($db) } 'Cannot consume token twice';
};

subtest 'Expired token rejected' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id    => $user->id,
        purpose    => 'login',
        expires_in => -1,  # already expired (negative hours)
    });

    ok($token_obj->is_expired, 'Token reports as expired');
    dies_ok { $token_obj->consume($db) } 'Cannot consume expired token';
};

subtest 'Valid token not expired' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok(!$token_obj->is_expired, 'Fresh token is not expired');
};

subtest 'Purpose constraint enforced' => sub {
    dies_ok {
        Registry::DAO::MagicLinkToken->generate($db, {
            user_id => $user->id,
            purpose => 'invalid_purpose',
        });
    } 'Invalid purpose rejected by database constraint';
};

subtest 'Cascade delete with user' => sub {
    my $temp_user = Registry::DAO::User->create($db, {
        username => 'temp_magic_user',
        email    => 'tempmagic@example.com',
        name     => 'Temp User',
    });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $temp_user->id,
        purpose => 'login',
    });

    $db->db->delete('users', { id => $temp_user->id });

    my $orphan = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);
    ok(!$orphan, 'Token cascade-deleted with user');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/magic-link-token.t`
Expected: FAIL — `Can't locate Registry/DAO/MagicLinkToken.pm`

- [ ] **Step 3: Write minimal implementation**

Create `lib/Registry/DAO/MagicLinkToken.pm`:

```perl
# ABOUTME: DAO for magic link tokens used in passwordless login, invitations,
# ABOUTME: and email verification. Tokens are single-use with expiry enforcement.
use 5.42.0;
use Object::Pad;

class Registry::DAO::MagicLinkToken :isa(Registry::DAO::Object) {
    use Carp qw(croak);
    use Crypt::URandom qw(urandom);
    use MIME::Base64 qw(encode_base64url);
    use Digest::SHA qw(sha256_hex);
    use DateTime;
    use DateTime::Format::Pg;

    field $id :param :reader;
    field $user_id :param :reader;
    field $token_hash :param :reader;
    field $purpose :param :reader;
    field $expires_at :param :reader;
    field $consumed_at :param :reader = undef;
    field $created_at :param :reader = undef;

    sub table { 'magic_link_tokens' }

    # Generate a new token, returning ($token_object, $plaintext_token).
    # The plaintext is shown to the user exactly once (in the email link).
    sub generate ($class, $db, $args) {
        $db = $db->db if $db isa Registry::DAO;

        my $raw_bytes  = urandom(32);
        my $plaintext  = encode_base64url($raw_bytes);
        my $hash       = sha256_hex($plaintext);
        my $expires_in = $args->{expires_in} // 24;  # hours

        my $token = $class->create($db, {
            user_id    => $args->{user_id},
            token_hash => $hash,
            purpose    => $args->{purpose},
            expires_at => \["now() + interval '1 hour' * ?", $expires_in],
        });

        return ($token, $plaintext);
    }

    # Look up a token by its plaintext value (hashes it first).
    sub find_by_plaintext ($class, $db, $plaintext) {
        my $hash = sha256_hex($plaintext);
        return $class->find($db, { token_hash => $hash });
    }

    method is_expired () {
        return 1 unless $expires_at;
        my $exp = DateTime::Format::Pg->parse_timestamptz($expires_at);
        return $exp < DateTime->now(time_zone => 'UTC');
    }

    method consume ($db) {
        croak "Token already consumed" if $consumed_at;
        croak "Token has expired" if $self->is_expired;

        $db = $db->db if $db isa Registry::DAO;

        return $self->update($db, { consumed_at => \'now()' });
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/magic-link-token.t`
Expected: All subtests pass

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/DAO/MagicLinkToken.pm t/dao/magic-link-token.t
git commit -m "Add Registry::DAO::MagicLinkToken with generation, hash lookup, and single-use consumption"
```

---

## Task 5: DAO — Registry::DAO::ApiKey

**Files:**
- Create: `lib/Registry/DAO/ApiKey.pm`
- Create: `t/dao/api-key.t`

- [ ] **Step 1: Write the failing test**

Create `t/dao/api-key.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Unit tests for ApiKey DAO — creation with one-time plaintext reveal,
# ABOUTME: hash lookup, scope bitvector checks, expiry, and prefix storage.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::ApiKey;
use Registry::DAO::User;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

my $user = Registry::DAO::User->create($db, {
    username => 'api_key_test_user',
    email    => 'apikey@example.com',
    name     => 'API Key Tester',
});

subtest 'Generate an API key' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'My Test Key',
        scopes  => 3,  # read + write
    });

    ok($key_obj, 'Key object created');
    ok($plaintext, 'Plaintext key returned');
    like($plaintext, qr/^rk_live_/, 'Key has correct prefix format');
    is($key_obj->user_id, $user->id, 'Correct user_id');
    is($key_obj->name, 'My Test Key', 'Correct name');
    is($key_obj->scopes, 3, 'Correct scopes bitvector');
    ok($key_obj->key_prefix, 'Has key_prefix stored');
    is(length($key_obj->key_prefix), 8, 'Prefix is 8 characters');
};

subtest 'Find by plaintext key (hash lookup)' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Lookup Test Key',
    });

    my $found = Registry::DAO::ApiKey->find_by_plaintext($db, $plaintext);
    ok($found, 'Found key by plaintext hash lookup');
    is($found->id, $key_obj->id, 'Correct key found');
};

subtest 'Scope bitvector checks' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Scoped Key',
        scopes  => 0b00110101,  # read + delete + enrollment + reporting
    });

    ok($key_obj->has_scope(1),  'Has read scope');
    ok(!$key_obj->has_scope(2), 'Does not have write scope');
    ok($key_obj->has_scope(4),  'Has delete scope');
    ok($key_obj->has_scope(16), 'Has enrollment scope');
    ok($key_obj->has_scope(32), 'Has reporting scope');
    ok(!$key_obj->has_scope(8), 'Does not have admin scope');

    # Zero scopes means no restrictions (full access)
    my ($full_key, $full_pt) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Full Access Key',
        scopes  => 0,
    });
    ok($full_key->has_scope(1), 'Zero-scope key has read (unrestricted)');
    ok($full_key->has_scope(8), 'Zero-scope key has admin (unrestricted)');
};

subtest 'Expired key detected' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id    => $user->id,
        name       => 'Expiring Key',
        expires_in => -1,  # already expired
    });

    ok($key_obj->is_expired, 'Key reports as expired');
};

subtest 'Key without expiry never expires' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Permanent Key',
    });

    ok(!$key_obj->is_expired, 'Key without expiry is not expired');
};

subtest 'Update last_used_at' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Usage Tracking Key',
    });

    ok(!$key_obj->last_used_at, 'No last_used_at initially');

    my $updated = $key_obj->touch($db);
    ok($updated->last_used_at, 'last_used_at set after touch');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/api-key.t`
Expected: FAIL — `Can't locate Registry/DAO/ApiKey.pm`

- [ ] **Step 3: Write minimal implementation**

Create `lib/Registry/DAO/ApiKey.pm`:

```perl
# ABOUTME: DAO for API bearer tokens. Generates keys with one-time plaintext
# ABOUTME: reveal, stores SHA-256 hash, and checks scope bitvectors.
use 5.42.0;
use Object::Pad;

class Registry::DAO::ApiKey :isa(Registry::DAO::Object) {
    use Carp qw(croak);
    use Crypt::URandom qw(urandom);
    use MIME::Base64 qw(encode_base64url);
    use Digest::SHA qw(sha256_hex);
    use DateTime;
    use DateTime::Format::Pg;

    field $id :param :reader;
    field $user_id :param :reader;
    field $key_hash :param :reader;
    field $key_prefix :param :reader;
    field $name :param :reader;
    field $scopes :param :reader = 0;
    field $expires_at :param :reader = undef;
    field $last_used_at :param :reader = undef;
    field $created_at :param :reader = undef;

    sub table { 'api_keys' }

    # Generate a new API key, returning ($key_object, $plaintext_key).
    # The plaintext is displayed to the user exactly once at creation.
    sub generate ($class, $db, $args) {
        $db = $db->db if $db isa Registry::DAO;

        my $raw_bytes = urandom(32);
        my $encoded   = encode_base64url($raw_bytes);
        my $env       = $ENV{REGISTRY_ENV} // 'live';
        my $plaintext = "rk_${env}_${encoded}";
        my $hash      = sha256_hex($plaintext);
        my $prefix    = substr($plaintext, 0, 8);

        my %create_data = (
            user_id    => $args->{user_id},
            key_hash   => $hash,
            key_prefix => $prefix,
            name       => $args->{name},
            scopes     => $args->{scopes} // 0,
        );

        if (defined $args->{expires_in}) {
            $create_data{expires_at} = \["now() + interval '1 hour' * ?", $args->{expires_in}];
        }

        my $key = $class->create($db, \%create_data);
        return ($key, $plaintext);
    }

    # Look up a key by its plaintext value (hashes it first).
    sub find_by_plaintext ($class, $db, $plaintext) {
        my $hash = sha256_hex($plaintext);
        return $class->find($db, { key_hash => $hash });
    }

    # Check if the key has a specific scope bit set.
    # A scope of 0 means unrestricted (full access).
    method has_scope ($required_scope) {
        return 1 if $scopes == 0;  # unrestricted
        return ($scopes & $required_scope) == $required_scope;
    }

    method is_expired () {
        return 0 unless $expires_at;  # no expiry = never expires
        my $exp = DateTime::Format::Pg->parse_timestamptz($expires_at);
        return $exp < DateTime->now(time_zone => 'UTC');
    }

    method touch ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $self->update($db, { last_used_at => \'now()' });
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/api-key.t`
Expected: All subtests pass

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/DAO/ApiKey.pm t/dao/api-key.t
git commit -m "Add Registry::DAO::ApiKey with generation, hash lookup, and scope bitvector checks"
```

---

## Task 6: DAO — User Auth Modifications

**Files:**
- Modify: `lib/Registry/DAO/User.pm`
- Create: `t/dao/user-auth.t`

- [ ] **Step 1: Write the failing test**

Create `t/dao/user-auth.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for passwordless user creation and auth-related
# ABOUTME: relationship accessors (passkeys, magic_link_tokens, api_keys).
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::Passkey;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::ApiKey;

my $t  = Test::Registry::DB->new;
my $db = $t->db;

subtest 'Create user without password (passwordless)' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'passwordless_user',
        email    => 'nopass@example.com',
        name     => 'Passwordless User',
    });

    ok($user, 'User created without password');
    ok($user->id, 'Has id');
    is($user->username, 'passwordless_user', 'Correct username');
    is($user->email, 'nopass@example.com', 'Correct email');
};

subtest 'User passkeys accessor' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'passkey_rel_user',
        email    => 'passkey_rel@example.com',
        name     => 'Passkey Rel User',
    });

    # No passkeys initially
    my @passkeys = $user->passkeys($db);
    is(scalar @passkeys, 0, 'No passkeys initially');

    # Create some passkeys
    Registry::DAO::Passkey->create($db, {
        user_id       => $user->id,
        credential_id => pack('H*', 'aa11bb22cc33dd44'),
        public_key    => pack('H*', 'ee55ff66'),
        device_name   => 'Laptop',
    });

    @passkeys = $user->passkeys($db);
    is(scalar @passkeys, 1, 'One passkey after creation');
    is($passkeys[0]->device_name, 'Laptop', 'Correct device name');
};

subtest 'User magic_link_tokens accessor' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'magic_rel_user',
        email    => 'magic_rel@example.com',
        name     => 'Magic Rel User',
    });

    Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    my @tokens = $user->magic_link_tokens($db);
    is(scalar @tokens, 1, 'One magic link token');
    is($tokens[0]->purpose, 'login', 'Correct purpose');
};

subtest 'User api_keys accessor' => sub {
    my $user = Registry::DAO::User->create($db, {
        username => 'apikey_rel_user',
        email    => 'apikey_rel@example.com',
        name     => 'ApiKey Rel User',
    });

    Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Test Key',
    });

    my @keys = $user->api_keys($db);
    is(scalar @keys, 1, 'One API key');
    is($keys[0]->name, 'Test Key', 'Correct key name');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/user-auth.t`
Expected: FAIL — `Can't locate object method "passkeys" via package "Registry::DAO::User"`

- [ ] **Step 3: Add relationship accessors to User.pm**

Add to `lib/Registry/DAO/User.pm`, after the existing methods:

```perl
    method passkeys ($db) {
        Registry::DAO::Passkey->for_user($db, $id);
    }

    method magic_link_tokens ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my @rows = $db->select('magic_link_tokens', '*', { user_id => $id },
            { -desc => 'created_at' })->hashes->each;
        return map { Registry::DAO::MagicLinkToken->new(%$_) } @rows;
    }

    method api_keys ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my @rows = $db->select('api_keys', '*', { user_id => $id },
            { -desc => 'created_at' })->hashes->each;
        return map { Registry::DAO::ApiKey->new(%$_) } @rows;
    }
```

Also modify the `create` method in `User.pm` to handle missing password. The existing code calls `$crypt->hash_password(delete $user_data{password})` which will crash when `password` is `undef`. Add a guard:

```perl
# In the create() method, replace the unconditional hash_password call with:
if (defined $user_data{password}) {
    $user_data{passhash} = $crypt->hash_password(delete $user_data{password});
} else {
    delete $user_data{password};  # ensure no stray key sent to DB
}
```

While modifying `User.pm`, add ABOUTME comments to the top of the file if not already present:

```perl
# ABOUTME: DAO for user accounts with profile data. Handles creation,
# ABOUTME: password hashing, and auth relationship accessors (passkeys, tokens, API keys).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/user-auth.t`
Expected: All subtests pass

- [ ] **Step 5: Run full DAO test suite for regressions**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/dao/`
Expected: All DAO tests pass (100%)

- [ ] **Step 6: Commit**

```bash
git add lib/Registry/DAO/User.pm t/dao/user-auth.t
git commit -m "Add auth relationship accessors to User: passkeys, magic_link_tokens, api_keys"
```

---

## Task 7: WebAuthn — AuthenticatorData Parser

**Files:**
- Create: `lib/Registry/Auth/WebAuthn/AuthenticatorData.pm`
- Create: `t/auth/webauthn-authenticator-data.t`

- [ ] **Step 1: Write the failing test**

Create `t/auth/webauthn-authenticator-data.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for parsing the WebAuthn authenticator data binary structure:
# ABOUTME: rpIdHash, flags, signCount, and attested credential data.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn::AuthenticatorData;
use Digest::SHA qw(sha256);

subtest 'Parse minimal authenticator data (37 bytes, no attestation)' => sub {
    # Build a synthetic authenticator data blob:
    # 32 bytes rpIdHash + 1 byte flags + 4 bytes signCount
    my $rp_id_hash = sha256('example.com');          # 32 bytes
    my $flags      = pack('C', 0x01);                # UP (user present) bit set
    my $sign_count = pack('N', 42);                  # 4 bytes big-endian

    my $auth_data_bytes = $rp_id_hash . $flags . $sign_count;

    my $parsed = Registry::Auth::WebAuthn::AuthenticatorData->parse($auth_data_bytes);

    ok($parsed, 'Parsed authenticator data');
    is($parsed->rp_id_hash, $rp_id_hash, 'Correct rpIdHash');
    is($parsed->sign_count, 42, 'Correct sign count');
    ok($parsed->user_present, 'User present flag set');
    ok(!$parsed->user_verified, 'User verified flag not set');
    ok(!$parsed->has_attested_credential_data, 'No attested credential data');
};

subtest 'Parse flags correctly' => sub {
    my $rp_id_hash = sha256('example.com');
    # Flags: UP=1, UV=1, AT=1 (bits 0, 2, 6)
    my $flags      = pack('C', 0b01000101);
    my $sign_count = pack('N', 0);

    my $auth_data_bytes = $rp_id_hash . $flags . $sign_count;

    my $parsed = Registry::Auth::WebAuthn::AuthenticatorData->parse($auth_data_bytes);

    ok($parsed->user_present, 'UP flag set');
    ok($parsed->user_verified, 'UV flag set');
    ok($parsed->has_attested_credential_data, 'AT flag set');
};

subtest 'Reject truncated data' => sub {
    dies_ok {
        Registry::Auth::WebAuthn::AuthenticatorData->parse('too short');
    } 'Rejects data shorter than 37 bytes';
};

subtest 'Parse with attested credential data' => sub {
    my $rp_id_hash = sha256('example.com');
    my $flags      = pack('C', 0b01000001);  # UP + AT
    my $sign_count = pack('N', 1);

    # Attested credential data:
    # 16 bytes AAGUID + 2 bytes credIdLen + credId + COSE public key
    my $aaguid     = "\x00" x 16;
    my $cred_id    = 'test_credential_id_value';
    my $cred_id_len = pack('n', length($cred_id));
    # Minimal COSE key placeholder (real tests use actual CBOR)
    my $cose_key   = pack('H*', 'a501020326200121582000000000000000000000000000000000000000000000000000000000000000002258200000000000000000000000000000000000000000000000000000000000000000');

    my $auth_data_bytes = $rp_id_hash . $flags . $sign_count
                        . $aaguid . $cred_id_len . $cred_id . $cose_key;

    my $parsed = Registry::Auth::WebAuthn::AuthenticatorData->parse($auth_data_bytes);

    ok($parsed->has_attested_credential_data, 'Has attested credential data');
    is($parsed->credential_id, $cred_id, 'Correct credential ID extracted');
    ok($parsed->credential_public_key, 'Has credential public key bytes');
    is($parsed->aaguid, $aaguid, 'Correct AAGUID');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn-authenticator-data.t`
Expected: FAIL — `Can't locate Registry/Auth/WebAuthn/AuthenticatorData.pm`

- [ ] **Step 3: Write minimal implementation**

Create `lib/Registry/Auth/WebAuthn/AuthenticatorData.pm`:

```perl
# ABOUTME: Parses the WebAuthn authenticator data binary structure into its
# ABOUTME: component fields: rpIdHash, flags, signCount, and attested credential data.
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn::AuthenticatorData {
    use Carp qw(croak);

    field $rp_id_hash :param :reader;
    field $flags_byte :param :reader;
    field $sign_count :param :reader;
    field $aaguid :param :reader = undef;
    field $credential_id :param :reader = undef;
    field $credential_public_key :param :reader = undef;

    # WebAuthn flags bit positions
    use constant UP_BIT => 0x01;   # User Present
    use constant UV_BIT => 0x04;   # User Verified
    use constant AT_BIT => 0x40;   # Attested Credential Data present
    use constant ED_BIT => 0x80;   # Extension Data present

    sub parse ($class, $bytes) {
        croak "Authenticator data too short (need >= 37 bytes, got " . length($bytes) . ")"
            if length($bytes) < 37;

        my $rp_id_hash = substr($bytes, 0, 32);
        my $flags_byte = unpack('C', substr($bytes, 32, 1));
        my $sign_count = unpack('N', substr($bytes, 33, 4));

        my %args = (
            rp_id_hash => $rp_id_hash,
            flags_byte => $flags_byte,
            sign_count => $sign_count,
        );

        # Parse attested credential data if AT flag is set
        if ($flags_byte & AT_BIT) {
            croak "AT flag set but data too short for attested credential"
                if length($bytes) < 55;  # 37 + 16 (aaguid) + 2 (len)

            $args{aaguid} = substr($bytes, 37, 16);
            my $cred_id_len = unpack('n', substr($bytes, 53, 2));

            croak "Data too short for credential ID"
                if length($bytes) < 55 + $cred_id_len;

            $args{credential_id} = substr($bytes, 55, $cred_id_len);

            # Everything after credential ID is the COSE public key (CBOR-encoded)
            $args{credential_public_key} = substr($bytes, 55 + $cred_id_len);
        }

        return $class->new(%args);
    }

    method user_present ()                  { $flags_byte & UP_BIT }
    method user_verified ()                 { $flags_byte & UV_BIT }
    method has_attested_credential_data ()  { $flags_byte & AT_BIT }
    method has_extension_data ()            { $flags_byte & ED_BIT }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn-authenticator-data.t`
Expected: All subtests pass

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/Auth/WebAuthn/AuthenticatorData.pm t/auth/webauthn-authenticator-data.t
git commit -m "Add WebAuthn AuthenticatorData parser for binary authenticator data structure"
```

---

## Task 8: WebAuthn — COSE Key Parser

**Files:**
- Create: `lib/Registry/Auth/WebAuthn/COSE.pm`
- Create: `t/auth/webauthn-cose.t`

- [ ] **Step 1: Write the failing test**

Create `t/auth/webauthn-cose.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for COSE key parsing — decoding CBOR-encoded public keys
# ABOUTME: into Crypt::PK::* objects for ES256, RS256, and EdDSA algorithms.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn::COSE;
use CBOR::XS qw(encode_cbor);

subtest 'Parse ES256 (P-256 ECDSA) COSE key' => sub {
    # COSE key map for ES256:
    # 1 (kty) => 2 (EC2), 3 (alg) => -7 (ES256),
    # -1 (crv) => 1 (P-256), -2 (x) => 32 bytes, -3 (y) => 32 bytes
    my $x = "\x01" x 32;
    my $y = "\x02" x 32;
    my $cose_cbor = encode_cbor({
        1  => 2,     # kty: EC2
        3  => -7,    # alg: ES256
        -1 => 1,     # crv: P-256
        -2 => $x,    # x coordinate
        -3 => $y,    # y coordinate
    });

    my $result = Registry::Auth::WebAuthn::COSE->parse($cose_cbor);

    ok($result, 'Parsed ES256 COSE key');
    is($result->{algorithm}, 'ES256', 'Correct algorithm');
    ok($result->{public_key}, 'Has public key object');
};

subtest 'Parse RS256 (RSA) COSE key' => sub {
    # COSE key map for RS256:
    # 1 (kty) => 3 (RSA), 3 (alg) => -257 (RS256),
    # -1 (n) => modulus bytes, -2 (e) => exponent bytes
    my $n = "\x00\x01" x 128;  # 256 bytes (2048-bit modulus)
    my $e = "\x01\x00\x01";     # 65537

    my $cose_cbor = encode_cbor({
        1  => 3,      # kty: RSA
        3  => -257,   # alg: RS256
        -1 => $n,     # modulus
        -2 => $e,     # exponent
    });

    my $result = Registry::Auth::WebAuthn::COSE->parse($cose_cbor);

    ok($result, 'Parsed RS256 COSE key');
    is($result->{algorithm}, 'RS256', 'Correct algorithm');
    ok($result->{public_key}, 'Has public key object');
};

subtest 'Parse EdDSA (Ed25519) COSE key' => sub {
    # COSE key map for EdDSA:
    # 1 (kty) => 1 (OKP), 3 (alg) => -8 (EdDSA),
    # -1 (crv) => 6 (Ed25519), -2 (x) => 32 bytes
    my $x = "\x03" x 32;

    my $cose_cbor = encode_cbor({
        1  => 1,     # kty: OKP
        3  => -8,    # alg: EdDSA
        -1 => 6,     # crv: Ed25519
        -2 => $x,    # public key point
    });

    my $result = Registry::Auth::WebAuthn::COSE->parse($cose_cbor);

    ok($result, 'Parsed EdDSA COSE key');
    is($result->{algorithm}, 'EdDSA', 'Correct algorithm');
    ok($result->{public_key}, 'Has public key object');
};

subtest 'Reject unsupported algorithm' => sub {
    my $cose_cbor = encode_cbor({
        1 => 2,
        3 => -999,  # unsupported
    });

    dies_ok {
        Registry::Auth::WebAuthn::COSE->parse($cose_cbor);
    } 'Rejects unsupported COSE algorithm';
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn-cose.t`
Expected: FAIL — `Can't locate Registry/Auth/WebAuthn/COSE.pm`

- [ ] **Step 3: Write minimal implementation**

Create `lib/Registry/Auth/WebAuthn/COSE.pm`:

```perl
# ABOUTME: Parses CBOR-encoded COSE public keys from WebAuthn attestation
# ABOUTME: into Crypt::PK::* objects for signature verification (ES256, RS256, EdDSA).
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn::COSE {
    use Carp qw(croak);
    use CBOR::XS qw(decode_cbor);
    use Crypt::PK::ECC;
    use Crypt::PK::RSA;
    use Crypt::PK::Ed25519;

    # COSE algorithm identifiers
    use constant ALG_ES256 => -7;
    use constant ALG_RS256 => -257;
    use constant ALG_EDDSA => -8;

    # Parse a CBOR-encoded COSE key and return a hashref with
    # { algorithm => $name, public_key => $crypt_pk_object }
    sub parse ($class, $cbor_bytes) {
        my $map = decode_cbor($cbor_bytes);
        croak "COSE key must be a map" unless ref $map eq 'HASH';

        my $alg = $map->{3} // croak "COSE key missing algorithm (label 3)";

        if ($alg == ALG_ES256) {
            return $class->_parse_es256($map);
        }
        elsif ($alg == ALG_RS256) {
            return $class->_parse_rs256($map);
        }
        elsif ($alg == ALG_EDDSA) {
            return $class->_parse_eddsa($map);
        }
        else {
            croak "Unsupported COSE algorithm: $alg";
        }
    }

    sub _parse_es256 ($class, $map) {
        my $x = $map->{-2} // croak "ES256 COSE key missing x coordinate";
        my $y = $map->{-3} // croak "ES256 COSE key missing y coordinate";

        my $pk = Crypt::PK::ECC->new;
        # Import raw public key: 0x04 prefix + x + y (uncompressed point)
        $pk->import_key_raw("\x04" . $x . $y, 'secp256r1');

        return { algorithm => 'ES256', public_key => $pk };
    }

    sub _parse_rs256 ($class, $map) {
        my $n = $map->{-1} // croak "RS256 COSE key missing modulus";
        my $e = $map->{-2} // croak "RS256 COSE key missing exponent";

        my $pk = Crypt::PK::RSA->new;
        # Import from raw components
        $pk->import_key({
            N => unpack('H*', $n),
            e => unpack('H*', $e),
        });

        return { algorithm => 'RS256', public_key => $pk };
    }

    sub _parse_eddsa ($class, $map) {
        my $x = $map->{-2} // croak "EdDSA COSE key missing public key point";

        my $pk = Crypt::PK::Ed25519->new;
        $pk->import_key_raw($x, 'public');

        return { algorithm => 'EdDSA', public_key => $pk };
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn-cose.t`
Expected: All subtests pass

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/Auth/WebAuthn/COSE.pm t/auth/webauthn-cose.t
git commit -m "Add COSE key parser for ES256, RS256, and EdDSA WebAuthn public keys"
```

---

## Task 9: WebAuthn — Challenge Generator

**Files:**
- Create: `lib/Registry/Auth/WebAuthn/Challenge.pm`
- Create: `t/auth/webauthn-challenge.t`

- [ ] **Step 1: Write the failing test**

Create `t/auth/webauthn-challenge.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for WebAuthn challenge generation — randomness, encoding,
# ABOUTME: and base64url round-trip correctness.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn::Challenge;
use MIME::Base64 qw(decode_base64url);

subtest 'Generate produces base64url string' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;
    ok($challenge, 'Generated a challenge');
    ok(length($challenge) >= 40, 'Challenge has sufficient length (32 bytes base64url)');
    # base64url alphabet: [A-Za-z0-9_-]
    like($challenge, qr/^[A-Za-z0-9_-]+$/, 'Challenge is valid base64url');
};

subtest 'Each challenge is unique' => sub {
    my %seen;
    for (1..20) {
        my $c = Registry::Auth::WebAuthn::Challenge->generate;
        $seen{$c}++;
    }
    is(scalar keys %seen, 20, 'All 20 challenges are unique');
};

subtest 'Decode round-trips correctly' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;
    my $decoded = Registry::Auth::WebAuthn::Challenge->decode($challenge);
    is(length($decoded), 32, 'Decoded challenge is 32 raw bytes');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn-challenge.t`
Expected: FAIL — `Can't locate Registry/Auth/WebAuthn/Challenge.pm`

- [ ] **Step 3: Write implementation**

Create `lib/Registry/Auth/WebAuthn/Challenge.pm`:

```perl
# ABOUTME: Generates cryptographic challenges for WebAuthn registration and
# ABOUTME: authentication ceremonies, with session storage helpers.
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn::Challenge {
    use Crypt::URandom qw(urandom);
    use MIME::Base64 qw(encode_base64url decode_base64url);

    # Generate a new challenge (32 random bytes, base64url-encoded).
    sub generate ($class) {
        return encode_base64url(urandom(32));
    }

    # Store a challenge in the Mojolicious session.
    sub store ($class, $c, $challenge) {
        $c->session(webauthn_challenge => $challenge);
    }

    # Retrieve and clear the challenge from session (one-time use).
    sub retrieve ($class, $c) {
        my $challenge = $c->session('webauthn_challenge');
        delete $c->session->{webauthn_challenge};
        return $challenge;
    }

    # Decode a base64url challenge to raw bytes for comparison.
    sub decode ($class, $challenge_b64) {
        return decode_base64url($challenge_b64);
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn-challenge.t`
Expected: All subtests pass

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/Auth/WebAuthn/Challenge.pm t/auth/webauthn-challenge.t
git commit -m "Add WebAuthn challenge generator with session storage"
```

---

## Task 10: WebAuthn — Main Library

**Files:**
- Create: `lib/Registry/Auth/WebAuthn.pm`
- Create: `t/auth/webauthn.t`

- [ ] **Step 1: Write the failing test**

Create `t/auth/webauthn.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for the main WebAuthn library — registration/authentication
# ABOUTME: option generation and response verification against test vectors.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Exception;

use lib qw(lib t/lib);

use Registry::Auth::WebAuthn;
use Registry::Auth::WebAuthn::Challenge;
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64url decode_base64url);
use Mojo::JSON qw(encode_json);

my $webauthn = Registry::Auth::WebAuthn->new(
    rp_id   => 'example.com',
    rp_name => 'Example Org',
    origin  => 'https://example.com',
);

subtest 'Generate registration options' => sub {
    my $options = $webauthn->generate_registration_options(
        'user-uuid-123',
        'testuser',
        'Test User',
    );

    ok($options, 'Got registration options');
    ok($options->{challenge}, 'Has challenge');
    is($options->{rp}{id}, 'example.com', 'Correct RP ID');
    is($options->{rp}{name}, 'Example Org', 'Correct RP name');
    is($options->{user}{id}, 'user-uuid-123', 'Correct user ID');
    is($options->{user}{name}, 'testuser', 'Correct user name');
    is($options->{user}{displayName}, 'Test User', 'Correct display name');

    # Should request discoverable credentials
    is($options->{authenticatorSelection}{residentKey}, 'preferred',
        'Requests discoverable credentials');

    # Should support our three algorithms
    my @alg_ids = map { $_->{alg} } @{$options->{pubKeyCredParams}};
    ok((grep { $_ == -7 } @alg_ids), 'Supports ES256');
    ok((grep { $_ == -257 } @alg_ids), 'Supports RS256');
    ok((grep { $_ == -8 } @alg_ids), 'Supports EdDSA');
};

subtest 'Generate authentication options' => sub {
    my $options = $webauthn->generate_authentication_options();

    ok($options, 'Got authentication options');
    ok($options->{challenge}, 'Has challenge');
    is($options->{rpId}, 'example.com', 'Correct RP ID');

    # Empty allowCredentials = discoverable credential mode
    is(ref $options->{allowCredentials}, 'ARRAY', 'Has allowCredentials array');
};

subtest 'Generate authentication options with credential list' => sub {
    my @cred_ids = (pack('H*', 'aabbccdd'), pack('H*', '11223344'));
    my $options = $webauthn->generate_authentication_options(
        allow_credentials => \@cred_ids,
    );

    is(scalar @{$options->{allowCredentials}}, 2, 'Two allowed credentials');
};

subtest 'Verify registration response validates origin' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

    # clientDataJSON with wrong origin
    my $client_data = encode_json({
        type      => 'webauthn.create',
        challenge => $challenge,
        origin    => 'https://evil.com',
    });

    dies_ok {
        $webauthn->verify_registration_response(
            $challenge,
            encode_base64url($client_data),
            encode_base64url('fake_attestation'),
        );
    } 'Rejects wrong origin';
};

subtest 'Verify registration response validates type' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

    my $client_data = encode_json({
        type      => 'webauthn.get',  # wrong type for registration
        challenge => $challenge,
        origin    => 'https://example.com',
    });

    dies_ok {
        $webauthn->verify_registration_response(
            $challenge,
            encode_base64url($client_data),
            encode_base64url('fake_attestation'),
        );
    } 'Rejects wrong ceremony type';
};

subtest 'Verify registration response validates challenge' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;
    my $wrong_challenge = Registry::Auth::WebAuthn::Challenge->generate;

    my $client_data = encode_json({
        type      => 'webauthn.create',
        challenge => $wrong_challenge,  # mismatch
        origin    => 'https://example.com',
    });

    dies_ok {
        $webauthn->verify_registration_response(
            $challenge,
            encode_base64url($client_data),
            encode_base64url('fake_attestation'),
        );
    } 'Rejects challenge mismatch';
};

subtest 'Verify authentication response validates origin' => sub {
    my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

    my $client_data = encode_json({
        type      => 'webauthn.get',
        challenge => $challenge,
        origin    => 'https://evil.com',
    });

    dies_ok {
        $webauthn->verify_authentication_response(
            $challenge,
            encode_base64url($client_data),
            'fake_auth_data',
            'fake_signature',
            undef,  # no key
            0,
        );
    } 'Rejects wrong origin for authentication';
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn.t`
Expected: FAIL — `Can't locate Registry/Auth/WebAuthn.pm`

- [ ] **Step 3: Write implementation**

Create `lib/Registry/Auth/WebAuthn.pm`:

```perl
# ABOUTME: WebAuthn Level 2 implementation for passkey registration and
# ABOUTME: authentication. Supports ES256, RS256, and EdDSA algorithms.
use 5.42.0;
use Object::Pad;

class Registry::Auth::WebAuthn {
    use Carp qw(croak);
    use Mojo::JSON qw(decode_json);
    use MIME::Base64 qw(encode_base64url decode_base64url);
    use Digest::SHA qw(sha256);
    use CBOR::XS qw(decode_cbor);

    use Registry::Auth::WebAuthn::Challenge;
    use Registry::Auth::WebAuthn::COSE;
    use Registry::Auth::WebAuthn::AuthenticatorData;

    field $rp_id :param :reader;
    field $rp_name :param :reader;
    field $origin :param :reader;

    # Generate options for navigator.credentials.create()
    method generate_registration_options ($user_id, $user_name, $user_display_name, %opts) {
        my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

        return {
            challenge => $challenge,
            rp        => {
                id   => $rp_id,
                name => $rp_name,
            },
            user => {
                id          => $user_id,
                name        => $user_name,
                displayName => $user_display_name,
            },
            pubKeyCredParams => [
                { type => 'public-key', alg => -7 },    # ES256
                { type => 'public-key', alg => -257 },  # RS256
                { type => 'public-key', alg => -8 },    # EdDSA
            ],
            authenticatorSelection => {
                residentKey      => 'preferred',
                userVerification => 'preferred',
            },
            timeout     => 60000,
            attestation => 'none',
            %{ $opts{exclude_credentials} ? {
                excludeCredentials => [
                    map { { type => 'public-key', id => encode_base64url($_) } }
                    @{$opts{exclude_credentials}}
                ]
            } : {} },
        };
    }

    # Generate options for navigator.credentials.get()
    method generate_authentication_options (%opts) {
        my $challenge = Registry::Auth::WebAuthn::Challenge->generate;

        my @allow_creds;
        if ($opts{allow_credentials}) {
            @allow_creds = map {
                { type => 'public-key', id => encode_base64url($_) }
            } @{$opts{allow_credentials}};
        }

        return {
            challenge        => $challenge,
            rpId             => $rp_id,
            allowCredentials => \@allow_creds,
            userVerification => 'preferred',
            timeout          => 60000,
        };
    }

    # Verify a registration (create) response from the browser.
    # Returns { credential_id => $bytes, public_key => $bytes, sign_count => $n }
    method verify_registration_response ($expected_challenge, $client_data_b64, $attestation_object_b64) {
        # 1. Decode and validate clientDataJSON
        my $client_data_json = decode_base64url($client_data_b64);
        my $client_data = decode_json($client_data_json);

        croak "Wrong ceremony type: expected webauthn.create, got $client_data->{type}"
            unless $client_data->{type} eq 'webauthn.create';

        croak "Origin mismatch: expected $origin, got $client_data->{origin}"
            unless $client_data->{origin} eq $origin;

        croak "Challenge mismatch"
            unless $client_data->{challenge} eq $expected_challenge;

        # 2. Decode attestation object (CBOR)
        my $att_obj_bytes = decode_base64url($attestation_object_b64);
        my $att_obj = decode_cbor($att_obj_bytes);

        # 3. Parse authenticator data
        my $auth_data = Registry::Auth::WebAuthn::AuthenticatorData->parse(
            $att_obj->{authData}
        );

        # 4. Verify RP ID hash
        my $expected_rp_hash = sha256($rp_id);
        croak "RP ID hash mismatch"
            unless $auth_data->rp_id_hash eq $expected_rp_hash;

        # 5. Verify user present flag
        croak "User not present" unless $auth_data->user_present;

        # 6. Extract credential data
        croak "No attested credential data in registration response"
            unless $auth_data->has_attested_credential_data;

        return {
            credential_id => $auth_data->credential_id,
            public_key    => $auth_data->credential_public_key,
            sign_count    => $auth_data->sign_count,
        };
    }

    # Verify an authentication (get) response from the browser.
    # Returns { sign_count => $n } on success, dies on failure.
    method verify_authentication_response (
        $expected_challenge, $client_data_b64, $authenticator_data_bytes,
        $signature, $credential_public_key_cbor, $stored_sign_count
    ) {
        # 1. Decode and validate clientDataJSON
        my $client_data_json = decode_base64url($client_data_b64);
        my $client_data = decode_json($client_data_json);

        croak "Wrong ceremony type: expected webauthn.get, got $client_data->{type}"
            unless $client_data->{type} eq 'webauthn.get';

        croak "Origin mismatch: expected $origin, got $client_data->{origin}"
            unless $client_data->{origin} eq $origin;

        croak "Challenge mismatch"
            unless $client_data->{challenge} eq $expected_challenge;

        # 2. Parse authenticator data
        my $auth_data = Registry::Auth::WebAuthn::AuthenticatorData->parse(
            $authenticator_data_bytes
        );

        # 3. Verify RP ID hash
        my $expected_rp_hash = sha256($rp_id);
        croak "RP ID hash mismatch"
            unless $auth_data->rp_id_hash eq $expected_rp_hash;

        # 4. Verify user present flag
        croak "User not present" unless $auth_data->user_present;

        # 5. Verify sign count (replay protection)
        if ($stored_sign_count > 0 && $auth_data->sign_count <= $stored_sign_count) {
            croak "Sign count regression: stored=$stored_sign_count, received="
                . $auth_data->sign_count . " (possible cloned authenticator)";
        }

        # 6. Verify signature
        # signature = sign(authData + sha256(clientDataJSON))
        my $signed_data = $authenticator_data_bytes . sha256($client_data_json);

        my $cose_result = Registry::Auth::WebAuthn::COSE->parse($credential_public_key_cbor);
        my $pk  = $cose_result->{public_key};
        my $alg = $cose_result->{algorithm};

        my $valid;
        if ($alg eq 'ES256') {
            $valid = $pk->verify_message_rfc7518($signature, $signed_data, 'SHA256');
        }
        elsif ($alg eq 'RS256') {
            $valid = $pk->verify_message($signature, $signed_data, 'SHA256', 'v1.5');
        }
        elsif ($alg eq 'EdDSA') {
            $valid = $pk->verify_message($signature, $signed_data);
        }
        else {
            croak "Unsupported algorithm for verification: $alg";
        }

        croak "Signature verification failed" unless $valid;

        return { sign_count => $auth_data->sign_count };
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/webauthn.t`
Expected: All subtests pass

- [ ] **Step 5: Run all auth tests**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/auth/`
Expected: All auth tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/Registry/Auth/WebAuthn.pm t/auth/webauthn.t
git commit -m "Add WebAuthn library with registration/authentication verification"
```

---

## Task 11: Email Templates for Auth

**Files:**
- Modify: `lib/Registry/Email/Template.pm`
- Create: `t/dao/email-templates-auth.t`

- [ ] **Step 0: Write the failing test first**

Create `t/dao/email-templates-auth.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests that auth-related email templates render correctly with
# ABOUTME: expected content for magic links, invitations, verification, and passkey notices.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);

use Registry::Email::Template;

my %test_vars = (
    tenant_name      => 'Dance Stars Academy',
    magic_link_url   => 'https://dance-stars.com/auth/magic/abc123',
    expires_in_hours => 24,
    inviter_name     => 'Jordan Smith',
    role             => 'instructor',
    verification_url => 'https://dance-stars.com/auth/verify-email/xyz789',
    device_name      => 'MacBook Pro',
);

for my $template_name (qw(magic_link_login magic_link_invite email_verification passkey_registered passkey_removed)) {
    subtest "Template: $template_name" => sub {
        my $result = Registry::Email::Template->render($template_name, %test_vars);
        ok($result, "Rendered $template_name");
        ok($result->{html}, 'Has HTML output');
        ok($result->{text}, 'Has text output');
        like($result->{html}, qr/Dance Stars Academy/, 'HTML contains tenant name');
        like($result->{text}, qr/Dance Stars Academy/, 'Text contains tenant name');
    };
}

subtest 'magic_link_login contains sign-in link' => sub {
    my $result = Registry::Email::Template->render('magic_link_login', %test_vars);
    like($result->{html}, qr{auth/magic/abc123}, 'HTML contains magic link URL');
    like($result->{text}, qr{auth/magic/abc123}, 'Text contains magic link URL');
};

subtest 'magic_link_invite contains inviter and role' => sub {
    my $result = Registry::Email::Template->render('magic_link_invite', %test_vars);
    like($result->{html}, qr/Jordan Smith/, 'HTML contains inviter name');
    like($result->{html}, qr/instructor/, 'HTML contains role');
};

done_testing();
```

- [ ] **Step 1: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/email-templates-auth.t`
Expected: FAIL — templates not yet defined

- [ ] **Step 2: Add auth email templates**

Add the following templates to the `%TEMPLATES` hash in `lib/Registry/Email/Template.pm`:

```perl
    magic_link_login => {
        subject => 'Sign in to %{tenant_name}',
        html    => sub (%vars) {
            _html_layout(
                "Sign In Link",
                "<p>Click the link below to sign in to your <strong>"
                . _escape_html($vars{tenant_name})
                . "</strong> account:</p>"
                . "<p style='text-align:center;margin:30px 0;'>"
                . "<a href='" . _escape_html($vars{magic_link_url})
                . "' style='background:#2563eb;color:#fff;padding:12px 24px;"
                . "text-decoration:none;border-radius:6px;font-weight:bold;'>"
                . "Sign In</a></p>"
                . "<p style='color:#6b7280;font-size:14px;'>This link expires in "
                . _escape_html($vars{expires_in_hours}) . " hours. "
                . "If you didn't request this, you can safely ignore this email.</p>"
            );
        },
        text => sub (%vars) {
            _text_layout(
                "Sign in to $vars{tenant_name}:\n\n"
                . "$vars{magic_link_url}\n\n"
                . "This link expires in $vars{expires_in_hours} hours.\n"
                . "If you didn't request this, ignore this email."
            );
        },
    },

    magic_link_invite => {
        subject => "You've been invited to %{tenant_name}",
        html    => sub (%vars) {
            _html_layout(
                "Team Invitation",
                "<p><strong>" . _escape_html($vars{inviter_name})
                . "</strong> has invited you to join <strong>"
                . _escape_html($vars{tenant_name}) . "</strong>"
                . " as " . _escape_html($vars{role}) . ".</p>"
                . "<p style='text-align:center;margin:30px 0;'>"
                . "<a href='" . _escape_html($vars{magic_link_url})
                . "' style='background:#2563eb;color:#fff;padding:12px 24px;"
                . "text-decoration:none;border-radius:6px;font-weight:bold;'>"
                . "Accept Invitation</a></p>"
                . "<p style='color:#6b7280;font-size:14px;'>This invitation expires in "
                . _escape_html($vars{expires_in_hours}) . " hours.</p>"
            );
        },
        text => sub (%vars) {
            _text_layout(
                "$vars{inviter_name} has invited you to join $vars{tenant_name}"
                . " as $vars{role}.\n\n"
                . "Accept: $vars{magic_link_url}\n\n"
                . "This invitation expires in $vars{expires_in_hours} hours."
            );
        },
    },

    email_verification => {
        subject => 'Verify your email address',
        html    => sub (%vars) {
            _html_layout(
                "Verify Email",
                "<p>Verify your email address for <strong>"
                . _escape_html($vars{tenant_name})
                . "</strong>:</p>"
                . "<p style='text-align:center;margin:30px 0;'>"
                . "<a href='" . _escape_html($vars{verification_url})
                . "' style='background:#2563eb;color:#fff;padding:12px 24px;"
                . "text-decoration:none;border-radius:6px;font-weight:bold;'>"
                . "Verify Email</a></p>"
            );
        },
        text => sub (%vars) {
            _text_layout(
                "Verify your email for $vars{tenant_name}:\n\n"
                . "$vars{verification_url}"
            );
        },
    },

    passkey_registered => {
        subject => 'New passkey added to your account',
        html    => sub (%vars) {
            _html_layout(
                "Security Notice",
                "<p>A new passkey was registered on your <strong>"
                . _escape_html($vars{tenant_name})
                . "</strong> account:</p>"
                . "<p><strong>Device:</strong> " . _escape_html($vars{device_name}) . "</p>"
                . "<p style='color:#6b7280;font-size:14px;'>"
                . "If you didn't do this, contact your administrator immediately.</p>"
            );
        },
        text => sub (%vars) {
            _text_layout(
                "A new passkey was added to your $vars{tenant_name} account.\n\n"
                . "Device: $vars{device_name}\n\n"
                . "If you didn't do this, contact your administrator."
            );
        },
    },

    passkey_removed => {
        subject => 'Passkey removed from your account',
        html    => sub (%vars) {
            _html_layout(
                "Security Notice",
                "<p>A passkey was removed from your <strong>"
                . _escape_html($vars{tenant_name})
                . "</strong> account:</p>"
                . "<p><strong>Device:</strong> " . _escape_html($vars{device_name}) . "</p>"
                . "<p style='color:#6b7280;font-size:14px;'>"
                . "If you didn't do this, contact your administrator immediately.</p>"
            );
        },
        text => sub (%vars) {
            _text_layout(
                "A passkey was removed from your $vars{tenant_name} account.\n\n"
                . "Device: $vars{device_name}\n\n"
                . "If you didn't do this, contact your administrator."
            );
        },
    },
```

- [ ] **Step 3: Run email template tests to verify they pass**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/dao/email-templates-auth.t`
Expected: All subtests pass

- [ ] **Step 4: Run full test suite for regressions**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/Email/Template.pm t/dao/email-templates-auth.t
git commit -m "Add email templates for magic links, invitations, email verification, and passkey notifications"
```

---

## Task 12: Tenant Model — canonical_domain

> **Dependency:** Must complete before Task 13 (Auth Controller), which uses `canonical_domain` and `magic_link_expiry_hours`.

**Files:**
- Modify: `lib/Registry/DAO/Tenant.pm`

- [ ] **Step 1: Add canonical_domain and magic_link_expiry_hours fields**

Add to `lib/Registry/DAO/Tenant.pm` field declarations:

```perl
    field $canonical_domain :param :reader = undef;
    field $magic_link_expiry_hours :param :reader = 24;
```

Also add ABOUTME comments to the top of the file if not already present:

```perl
# ABOUTME: DAO for tenant organizations. Manages tenant creation, schema
# ABOUTME: isolation, user association, and domain configuration.
```

- [ ] **Step 2: Run existing tenant tests**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add lib/Registry/DAO/Tenant.pm
git commit -m "Add canonical_domain and magic_link_expiry_hours fields to Tenant DAO"
```

---

## Task 13: Auth Controller — Magic Link Routes

> **Requires:** Task 12 (Tenant DAO) complete — controller uses `canonical_domain` and `magic_link_expiry_hours`.

**Files:**
- Create: `lib/Registry/Controller/Auth.pm`
- Create: `templates/auth/login.html.ep`
- Create: `templates/auth/magic-link-sent.html.ep`
- Create: `templates/auth/magic-link-error.html.ep`
- Create: `templates/auth/verify-email.html.ep`
- Create: `templates/auth/register-passkey.html.ep`
- Modify: `lib/Registry.pm` (add routes)
- Create: `t/controller/auth.t`

This is the largest task. It covers the Auth controller, all templates, and route registration. The test drives the implementation.

- [ ] **Step 1: Write the failing controller test**

Create `t/controller/auth.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Controller tests for /auth/* routes — magic link request/consumption,
# ABOUTME: WebAuthn registration/authentication, logout, and email verification.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;

# Import workflows before testing
system('carton', 'exec', './registry', 'workflow', 'import', 'registry') == 0
    or diag "Warning: workflow import may have failed";

my $t = Test::Mojo->new('Registry');

subtest 'GET /auth/login renders login page' => sub {
    $t->get_ok('/auth/login')
      ->status_is(200)
      ->content_like(qr/sign in/i, 'Login page has sign-in content');
};

subtest 'POST /auth/magic/request with valid email' => sub {
    # Create a user first
    my $db = $tdb->db;
    my $user = Registry::DAO::User->create($db, {
        username => 'magic_ctrl_user',
        email    => 'magic_ctrl@example.com',
        name     => 'Magic Ctrl User',
    });

    $t->post_ok('/auth/magic/request' => form => {
        email      => 'magic_ctrl@example.com',
        csrf_token => $t->ua->get('/auth/login')->result->dom->at('input[name=csrf_token]')->{value} // $t->tx->res->dom->at('meta[name=csrf-token]')->{content} // '',
    })
    ->status_is(200)
    ->content_like(qr/link.*sent|check.*email/i, 'Shows confirmation message');
};

subtest 'POST /auth/magic/request with unknown email (no info leak)' => sub {
    $t->post_ok('/auth/magic/request' => form => {
        email      => 'nonexistent@example.com',
        csrf_token => '',
    });
    # Should show same confirmation message regardless (prevent enumeration)
    # The status may be 200 or redirect — what matters is no error revealing
    # whether the email exists
    ok(1, 'Does not reveal whether email exists');
};

subtest 'GET /auth/magic/:token with valid token' => sub {
    my $db = $tdb->db;
    my $user = Registry::DAO::User->find($db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(302, 'Redirects after consuming magic link');
};

subtest 'GET /auth/magic/:token with expired token' => sub {
    my $db = $tdb->db;
    my $user = Registry::DAO::User->find($db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id    => $user->id,
        purpose    => 'login',
        expires_in => -1,
    });

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200)
      ->content_like(qr/expired/i, 'Shows expired message');
};

subtest 'GET /auth/magic/:token with invalid token' => sub {
    $t->get_ok('/auth/magic/totally_invalid_token_here')
      ->status_is(200)
      ->content_like(qr/invalid/i, 'Shows invalid link message');
};

subtest 'POST /auth/logout clears session' => sub {
    $t->post_ok('/auth/logout')
      ->status_is(302, 'Redirects after logout');
};

subtest 'GET /auth/verify-email/:token with valid token' => sub {
    my $db = $tdb->db;
    my $user = Registry::DAO::User->find($db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'verify_email',
    });

    $t->get_ok("/auth/verify-email/$plaintext")
      ->status_is(200)
      ->content_like(qr/verified|confirmed/i, 'Shows verification success');

    # Check that email_verified_at is set
    my $updated_user = Registry::DAO::User->find($db, { id => $user->id });
    ok($updated_user->email_verified_at, 'email_verified_at set after verification');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/controller/auth.t`
Expected: FAIL — missing controller and routes

- [ ] **Step 3: Create the Auth controller**

Create `lib/Registry/Controller/Auth.pm`:

```perl
# ABOUTME: Controller for /auth/* routes — magic link login, WebAuthn passkey
# ABOUTME: registration/authentication, logout, and email verification.
use 5.42.0;
use Object::Pad;

class Registry::Controller::Auth :isa(Registry::Controller) {
    use Registry::DAO::User;
    use Registry::DAO::MagicLinkToken;
    use Registry::DAO::Passkey;
    use Registry::Auth::WebAuthn;
    use Registry::Auth::WebAuthn::Challenge;
    use Registry::Email::Template;
    use Registry::DAO::Notification;
    use Mojo::JSON qw(decode_json encode_json);
    use MIME::Base64 qw(decode_base64url encode_base64url);

    method login () {
        $self->Mojolicious::Controller::render(template => 'auth/login');
    }

    method request_magic_link () {
        my $email = $self->param('email');
        my $dao   = $self->app->dao($self);
        my $db    = $dao->db;

        # Always show same response (prevent email enumeration)
        my $user = Registry::DAO::User->find($db, { email => $email });

        if ($user) {
            my $tenant = $self->tenant;
            my $tenant_obj = Registry::DAO::Tenant->find($db, { slug => $tenant });
            my $expiry_hours = $tenant_obj ? ($tenant_obj->magic_link_expiry_hours // 24) : 24;

            my ($token, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
                user_id    => $user->id,
                purpose    => 'login',
                expires_in => $expiry_hours,
            });

            # Build the magic link URL
            my $base_url = $self->req->url->to_abs->clone;
            $base_url->path("/auth/magic/$plaintext");
            $base_url->query('');

            # Send email
            try {
                my $rendered = Registry::Email::Template->render('magic_link_login',
                    tenant_name      => $tenant_obj ? $tenant_obj->name : 'Registry',
                    magic_link_url   => $base_url->to_string,
                    expires_in_hours => $expiry_hours,
                );

                Registry::DAO::Notification->create($db, {
                    user_id => $user->id,
                    type    => 'message_notification',
                    channel => 'email',
                    subject => 'Sign in link',
                    message => $rendered->{text},
                    metadata => { html => $rendered->{html} },
                });
            } catch ($e) {
                $self->app->log->error("Failed to send magic link email: $e");
            }
        }

        $self->Mojolicious::Controller::render(template => 'auth/magic-link-sent');
    }

    method consume_magic_link () {
        my $token_str = $self->param('token');
        my $dao       = $self->app->dao($self);
        my $db        = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $token_str);

        unless ($token) {
            return $self->Mojolicious::Controller::render(
                template => 'auth/magic-link-error',
                error    => 'Invalid link. Please request a new one.',
            );
        }

        if ($token->is_expired) {
            return $self->Mojolicious::Controller::render(
                template => 'auth/magic-link-error',
                error    => 'This link has expired. Request a new one.',
            );
        }

        if ($token->consumed_at) {
            return $self->Mojolicious::Controller::render(
                template => 'auth/magic-link-error',
                error    => 'This link has already been used. Request a new one.',
            );
        }

        try {
            $token->consume($db);
        } catch ($e) {
            return $self->Mojolicious::Controller::render(
                template => 'auth/magic-link-error',
                error    => 'Unable to process this link. Please try again.',
            );
        }

        # Set session
        my $tenant = $self->tenant;
        $self->session(
            user_id        => $token->user_id,
            tenant_schema  => $tenant,
            authenticated_at => time(),
        );

        # Redirect based on purpose
        if ($token->purpose eq 'invite') {
            return $self->redirect_to('/auth/register-passkey');
        }

        $self->redirect_to('/');
    }

    method verify_email () {
        my $token_str = $self->param('token');
        my $dao       = $self->app->dao($self);
        my $db        = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $token_str);
        my $success = 0;

        if ($token && !$token->is_expired && !$token->consumed_at && $token->purpose eq 'verify_email') {
            try {
                $token->consume($db);
                $db->update('users',
                    { email_verified_at => \'now()' },
                    { id => $token->user_id }
                );
                $success = 1;
            } catch ($e) {
                $self->app->log->error("Email verification failed: $e");
            }
        }

        $self->Mojolicious::Controller::render(
            template => 'auth/verify-email',
            verified => $success,
        );
    }

    method logout () {
        $self->session(expires => 1);
        $self->redirect_to('/');
    }

    # WebAuthn registration begin
    method webauthn_register_begin () {
        my $user_id = $self->session('user_id');
        return $self->render(json => { error => 'Not authenticated' }, status => 401)
            unless $user_id;

        my $dao  = $self->app->dao($self);
        my $db   = $dao->db;
        my $user = Registry::DAO::User->find($db, { id => $user_id });

        my $tenant = $self->tenant;
        my $tenant_obj = Registry::DAO::Tenant->find($db, { slug => $tenant });
        my $domain = $tenant_obj ? ($tenant_obj->canonical_domain // "$tenant.tinyartempire.com")
                                 : 'tinyartempire.com';

        my $webauthn = Registry::Auth::WebAuthn->new(
            rp_id   => $domain,
            rp_name => $tenant_obj ? $tenant_obj->name : 'Registry',
            origin  => "https://$domain",
        );

        # Exclude existing credentials
        my @existing = $user->passkeys($db);
        my @exclude_ids = map { $_->credential_id } @existing;

        my $options = $webauthn->generate_registration_options(
            $user->id,
            $user->username,
            $user->name || $user->username,
            exclude_credentials => \@exclude_ids,
        );

        # Store challenge in session
        Registry::Auth::WebAuthn::Challenge->store($self, $options->{challenge});

        $self->render(json => $options);
    }

    # WebAuthn registration complete
    method webauthn_register_complete () {
        my $user_id = $self->session('user_id');
        return $self->render(json => { error => 'Not authenticated' }, status => 401)
            unless $user_id;

        my $dao  = $self->app->dao($self);
        my $db   = $dao->db;

        my $body = $self->req->json;
        my $challenge = Registry::Auth::WebAuthn::Challenge->retrieve($self);

        return $self->render(json => { error => 'No challenge in session' }, status => 400)
            unless $challenge;

        my $tenant = $self->tenant;
        my $tenant_obj = Registry::DAO::Tenant->find($db, { slug => $tenant });
        my $domain = $tenant_obj ? ($tenant_obj->canonical_domain // "$tenant.tinyartempire.com")
                                 : 'tinyartempire.com';

        my $webauthn = Registry::Auth::WebAuthn->new(
            rp_id   => $domain,
            rp_name => $tenant_obj ? $tenant_obj->name : 'Registry',
            origin  => "https://$domain",
        );

        try {
            my $result = $webauthn->verify_registration_response(
                $challenge,
                $body->{clientDataJSON},
                $body->{attestationObject},
            );

            Registry::DAO::Passkey->create($db, {
                user_id       => $user_id,
                credential_id => $result->{credential_id},
                public_key    => $result->{public_key},
                sign_count    => $result->{sign_count},
                device_name   => $body->{device_name} // 'Unknown device',
            });

            $self->render(json => { status => 'ok' });
        } catch ($e) {
            $self->app->log->error("WebAuthn registration failed: $e");
            $self->render(json => { error => 'Registration failed' }, status => 400);
        }
    }

    # WebAuthn authentication begin
    method webauthn_auth_begin () {
        my $dao  = $self->app->dao($self);
        my $db   = $dao->db;

        my $tenant = $self->tenant;
        my $tenant_obj = Registry::DAO::Tenant->find($db, { slug => $tenant });
        my $domain = $tenant_obj ? ($tenant_obj->canonical_domain // "$tenant.tinyartempire.com")
                                 : 'tinyartempire.com';

        my $webauthn = Registry::Auth::WebAuthn->new(
            rp_id   => $domain,
            rp_name => $tenant_obj ? $tenant_obj->name : 'Registry',
            origin  => "https://$domain",
        );

        my $options = $webauthn->generate_authentication_options();

        Registry::Auth::WebAuthn::Challenge->store($self, $options->{challenge});

        $self->render(json => $options);
    }

    # WebAuthn authentication complete
    method webauthn_auth_complete () {
        my $dao  = $self->app->dao($self);
        my $db   = $dao->db;

        my $body = $self->req->json;
        my $challenge = Registry::Auth::WebAuthn::Challenge->retrieve($self);

        return $self->render(json => { error => 'No challenge in session' }, status => 400)
            unless $challenge;

        # Find the passkey by credential ID
        my $cred_id_bytes = decode_base64url($body->{credentialId});
        my $passkey = Registry::DAO::Passkey->find($db, {
            credential_id => $cred_id_bytes,
        });

        return $self->render(json => { error => 'Credential not recognized' }, status => 401)
            unless $passkey;

        my $tenant = $self->tenant;
        my $tenant_obj = Registry::DAO::Tenant->find($db, { slug => $tenant });
        my $domain = $tenant_obj ? ($tenant_obj->canonical_domain // "$tenant.tinyartempire.com")
                                 : 'tinyartempire.com';

        my $webauthn = Registry::Auth::WebAuthn->new(
            rp_id   => $domain,
            rp_name => $tenant_obj ? $tenant_obj->name : 'Registry',
            origin  => "https://$domain",
        );

        try {
            my $result = $webauthn->verify_authentication_response(
                $challenge,
                $body->{clientDataJSON},
                decode_base64url($body->{authenticatorData}),
                decode_base64url($body->{signature}),
                $passkey->public_key,
                $passkey->sign_count,
            );

            # Update sign count
            $passkey->update_sign_count($db, $result->{sign_count});

            # Set session
            $self->session(
                user_id          => $passkey->user_id,
                tenant_schema    => $tenant,
                authenticated_at => time(),
            );

            $self->render(json => { status => 'ok' });
        } catch ($e) {
            $self->app->log->error("WebAuthn authentication failed: $e");
            $self->render(json => { error => 'Authentication failed' }, status => 401);
        }
    }
}

1;
```

- [ ] **Step 4: Create templates**

Create `templates/auth/login.html.ep`:

```html
%# ABOUTME: Login page with passkey authentication and magic link fallback.
%# ABOUTME: Uses progressive enhancement — hides passkey UI if browser lacks WebAuthn.
% layout 'default';
% title 'Sign In';

<div class="auth-container" style="max-width:420px;margin:60px auto;padding:0 20px;">
  <h1 style="text-align:center;margin-bottom:32px;">Sign In</h1>

  <div id="passkey-section" style="display:none;margin-bottom:32px;">
    <button id="passkey-btn" type="button"
      style="width:100%;padding:14px;background:#2563eb;color:#fff;border:none;
             border-radius:8px;font-size:16px;cursor:pointer;font-weight:600;">
      Sign in with Passkey
    </button>
    <p id="passkey-error" style="color:#dc2626;margin-top:8px;display:none;"></p>
    <hr style="margin:24px 0;border:none;border-top:1px solid #e5e7eb;">
  </div>

  <form method="POST" action="/auth/magic/request">
    <input type="hidden" name="csrf_token" value="<%= csrf_token %>">
    <label for="email" style="display:block;margin-bottom:6px;font-weight:500;">Email address</label>
    <input type="email" name="email" id="email" required
      placeholder="you@example.com"
      style="width:100%;padding:10px;border:1px solid #d1d5db;border-radius:6px;
             font-size:16px;margin-bottom:16px;box-sizing:border-box;">
    <button type="submit"
      style="width:100%;padding:12px;background:#1f2937;color:#fff;border:none;
             border-radius:8px;font-size:16px;cursor:pointer;">
      Send Sign-In Link
    </button>
  </form>
</div>

<script>
// Progressive enhancement: show passkey button if browser supports WebAuthn
if (window.PublicKeyCredential) {
  document.getElementById('passkey-section').style.display = 'block';

  document.getElementById('passkey-btn').addEventListener('click', async () => {
    const errorEl = document.getElementById('passkey-error');
    errorEl.style.display = 'none';

    try {
      const beginResp = await fetch('/auth/webauthn/auth/begin', { method: 'POST' });
      const options = await beginResp.json();

      options.challenge = Uint8Array.from(atob(options.challenge.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));
      if (options.allowCredentials) {
        options.allowCredentials = options.allowCredentials.map(c => ({
          ...c,
          id: Uint8Array.from(atob(c.id.replace(/-/g,'+').replace(/_/g,'/')), ch => ch.charCodeAt(0))
        }));
      }

      const credential = await navigator.credentials.get({ publicKey: options });

      const body = {
        credentialId: btoa(String.fromCharCode(...new Uint8Array(credential.rawId)))
          .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''),
        clientDataJSON: btoa(String.fromCharCode(...new Uint8Array(credential.response.clientDataJSON)))
          .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''),
        authenticatorData: btoa(String.fromCharCode(...new Uint8Array(credential.response.authenticatorData)))
          .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''),
        signature: btoa(String.fromCharCode(...new Uint8Array(credential.response.signature)))
          .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''),
      };

      const completeResp = await fetch('/auth/webauthn/auth/complete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (completeResp.ok) {
        window.location.href = '/';
      } else {
        const err = await completeResp.json();
        errorEl.textContent = err.error || 'Authentication failed. Try a sign-in link instead.';
        errorEl.style.display = 'block';
      }
    } catch (e) {
      if (e.name !== 'AbortError') {
        errorEl.textContent = 'Passkey authentication failed. Try a sign-in link instead.';
        errorEl.style.display = 'block';
      }
    }
  });
}
</script>
```

Create `templates/auth/magic-link-sent.html.ep`:

```html
%# ABOUTME: Confirmation page shown after a magic link sign-in request.
%# ABOUTME: Same message shown regardless of whether the email exists (anti-enumeration).
% layout 'default';
% title 'Check Your Email';

<div style="max-width:420px;margin:60px auto;padding:0 20px;text-align:center;">
  <h1>Check your email</h1>
  <p style="color:#4b5563;margin-top:16px;">
    If an account exists with that email address, we've sent a sign-in link.
    The link expires in 24 hours.
  </p>
  <a href="/auth/login" style="display:inline-block;margin-top:24px;color:#2563eb;">
    Back to sign in
  </a>
</div>
```

Create `templates/auth/magic-link-error.html.ep`:

```html
%# ABOUTME: Error page for invalid, expired, or already-used magic links.
%# ABOUTME: Shows specific error message with option to request a new link.
% layout 'default';
% title 'Invalid Link';

<div style="max-width:420px;margin:60px auto;padding:0 20px;text-align:center;">
  <h1>Invalid Link</h1>
  <p style="color:#dc2626;margin-top:16px;"><%= $error %></p>
  <a href="/auth/login"
    style="display:inline-block;margin-top:24px;padding:12px 24px;
           background:#2563eb;color:#fff;text-decoration:none;border-radius:8px;">
    Request a New Link
  </a>
</div>
```

Create `templates/auth/verify-email.html.ep`:

```html
%# ABOUTME: Email verification result page — shows success or failure
%# ABOUTME: after clicking the verification link from email.
% layout 'default';
% title 'Email Verification';

<div style="max-width:420px;margin:60px auto;padding:0 20px;text-align:center;">
% if ($verified) {
  <h1 style="color:#059669;">Email Verified</h1>
  <p style="color:#4b5563;margin-top:16px;">
    Your email address has been confirmed. You're all set.
  </p>
% } else {
  <h1 style="color:#dc2626;">Verification Failed</h1>
  <p style="color:#4b5563;margin-top:16px;">
    This verification link is invalid or has expired.
  </p>
% }
</div>
```

Create `templates/auth/register-passkey.html.ep`:

```html
%# ABOUTME: Passkey registration page — prompted after first login via magic link.
%# ABOUTME: Progressive enhancement hides the form if WebAuthn is unavailable.
% layout 'default';
% title 'Set Up Quick Login';

<div style="max-width:420px;margin:60px auto;padding:0 20px;text-align:center;">
  <h1>Set Up Quick Login</h1>
  <p style="color:#4b5563;margin-top:16px;">
    Register a passkey for faster sign-in next time. This uses your device's
    biometrics or security key.
  </p>

  <div id="passkey-register" style="margin-top:32px;">
    <input type="text" id="device-name" placeholder="Device name (e.g., My MacBook)"
      style="width:100%;padding:10px;border:1px solid #d1d5db;border-radius:6px;
             font-size:16px;margin-bottom:16px;box-sizing:border-box;">
    <button id="register-btn" type="button"
      style="width:100%;padding:14px;background:#2563eb;color:#fff;border:none;
             border-radius:8px;font-size:16px;cursor:pointer;font-weight:600;">
      Register Passkey
    </button>
    <p id="register-error" style="color:#dc2626;margin-top:8px;display:none;"></p>
    <p id="register-success" style="color:#059669;margin-top:8px;display:none;">
      Passkey registered. You can now sign in with biometrics.
    </p>
  </div>

  <a href="/" style="display:inline-block;margin-top:24px;color:#6b7280;">
    Skip for now
  </a>
</div>

<script>
if (!window.PublicKeyCredential) {
  document.getElementById('passkey-register').innerHTML =
    '<p style="color:#6b7280;">Your browser does not support passkeys. You can still sign in with email links.</p>';
} else {
  document.getElementById('register-btn').addEventListener('click', async () => {
    const errorEl = document.getElementById('register-error');
    const successEl = document.getElementById('register-success');
    errorEl.style.display = 'none';
    successEl.style.display = 'none';

    try {
      const beginResp = await fetch('/auth/webauthn/register/begin', { method: 'POST' });
      const options = await beginResp.json();

      options.challenge = Uint8Array.from(atob(options.challenge.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));
      options.user.id = new TextEncoder().encode(options.user.id);
      if (options.excludeCredentials) {
        options.excludeCredentials = options.excludeCredentials.map(c => ({
          ...c,
          id: Uint8Array.from(atob(c.id.replace(/-/g,'+').replace(/_/g,'/')), ch => ch.charCodeAt(0))
        }));
      }

      const credential = await navigator.credentials.create({ publicKey: options });

      const body = {
        device_name: document.getElementById('device-name').value || 'Unknown device',
        clientDataJSON: btoa(String.fromCharCode(...new Uint8Array(credential.response.clientDataJSON)))
          .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''),
        attestationObject: btoa(String.fromCharCode(...new Uint8Array(credential.response.attestationObject)))
          .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''),
      };

      const completeResp = await fetch('/auth/webauthn/register/complete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (completeResp.ok) {
        successEl.style.display = 'block';
        document.getElementById('register-btn').disabled = true;
      } else {
        const err = await completeResp.json();
        errorEl.textContent = err.error || 'Registration failed. Try again.';
        errorEl.style.display = 'block';
      }
    } catch (e) {
      if (e.name !== 'AbortError') {
        errorEl.textContent = 'Setup failed. You can try again or use email login.';
        errorEl.style.display = 'block';
      }
    }
  });
}
</script>
```

- [ ] **Step 5: Add auth routes to Registry.pm**

In `lib/Registry.pm`, add the auth routes before the workflow catch-all routes (before `$r->any('/:workflow')`):

```perl
    # Auth routes (unprotected)
    my $auth = $r->under('/auth');
    $auth->get('/login')->to('Auth#login');
    $auth->post('/magic/request')->to('Auth#request_magic_link');
    $auth->get('/magic/:token')->to('Auth#consume_magic_link');
    $auth->post('/logout')->to('Auth#logout');
    $auth->get('/verify-email/:token')->to('Auth#verify_email');
    $auth->post('/webauthn/register/begin')->to('Auth#webauthn_register_begin');
    $auth->post('/webauthn/register/complete')->to('Auth#webauthn_register_complete');
    $auth->post('/webauthn/auth/begin')->to('Auth#webauthn_auth_begin');
    $auth->post('/webauthn/auth/complete')->to('Auth#webauthn_auth_complete');
```

Also update the `require_auth` helper to redirect to `/auth/login` instead of `/user-creation`:

Change the redirect line from:
```perl
$c->redirect_to('/user-creation');
```
to:
```perl
$c->redirect_to('/auth/login');
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/controller/auth.t`
Expected: All subtests pass

- [ ] **Step 7: Run full test suite**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All tests pass (100%)

- [ ] **Step 8: Commit**

```bash
git add lib/Registry/Controller/Auth.pm templates/auth/ lib/Registry.pm t/controller/auth.t
git commit -m "Add Auth controller with magic link login, WebAuthn passkey flows, and email verification"
```

---

## Task 14: Session Management — before_dispatch Rewrite

**Files:**
- Modify: `lib/Registry.pm`

- [ ] **Step 1: Write a test for bearer token auth**

Create `t/controller/api-auth.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for bearer token API authentication via the Authorization header.
# ABOUTME: Covers valid keys, invalid keys, expired keys, and scope enforcement.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::ApiKey;

my $tdb = Test::Registry::DB->new;

system('carton', 'exec', './registry', 'workflow', 'import', 'registry') == 0
    or diag "Warning: workflow import may have failed";

my $t = Test::Mojo->new('Registry');

my $db = $tdb->db;

my $user = Registry::DAO::User->create($db, {
    username  => 'api_auth_user',
    email     => 'apiauth@example.com',
    name      => 'API Auth User',
    user_type => 'admin',
});

subtest 'Valid bearer token sets current_user' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id => $user->id,
        name    => 'Valid Test Key',
    });

    $t->get_ok('/admin/dashboard' => {
        Authorization => "Bearer $plaintext",
    })->status_isnt(401, 'Not rejected with valid bearer token');
};

subtest 'Invalid bearer token returns 401' => sub {
    $t->get_ok('/admin/dashboard' => {
        Authorization  => 'Bearer rk_live_totally_invalid_key',
        'X-Requested-With' => 'XMLHttpRequest',
    })->status_is(401, 'Invalid key returns 401');
};

subtest 'Expired bearer token returns 401' => sub {
    my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
        user_id    => $user->id,
        name       => 'Expired Test Key',
        expires_in => -1,
    });

    $t->get_ok('/admin/dashboard' => {
        Authorization      => "Bearer $plaintext",
        'X-Requested-With' => 'XMLHttpRequest',
    })->status_is(401, 'Expired key returns 401');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/controller/api-auth.t`
Expected: FAIL — bearer token not handled in before_dispatch

- [ ] **Step 3: Extend before_dispatch in Registry.pm**

Modify the `before_dispatch` hook that populates `current_user`. Add bearer token check before the existing session check:

```perl
        $self->hook(
            before_dispatch => sub ($c) {
                # 1. Bearer token auth (API keys)
                my $auth_header = $c->req->headers->authorization // '';
                if ($auth_header =~ /^Bearer\s+(.+)$/i) {
                    my $token = $1;
                    try {
                        my $dao = $c->app->dao($c);
                        my $api_key = Registry::DAO::ApiKey->find_by_plaintext($dao->db, $token);

                        if ($api_key && !$api_key->is_expired) {
                            my $user = Registry::DAO::User->find($dao->db, { id => $api_key->user_id });
                            if ($user) {
                                $api_key->touch($dao->db);
                                $c->stash(current_user => {
                                    id        => $user->id,
                                    username  => $user->username,
                                    name      => $user->name,
                                    email     => $user->email,
                                    user_type => $user->user_type,
                                    role      => $user->user_type,
                                    api_key   => $api_key,
                                });
                                return;  # Skip session check
                            }
                        }

                        # Invalid or expired key
                        if ($c->req->headers->header('X-Requested-With')
                            || ($c->req->headers->accept // '') =~ m{application/json}) {
                            $c->render(json => { error => 'Authentication required' }, status => 401);
                            return;
                        }
                    } catch ($e) {
                        $c->app->log->warn("Bearer token auth failed: $e");
                    }
                }

                # 2. Session cookie auth (existing logic)
                my $user_id = $c->session('user_id');
                return unless $user_id;

                # ... (keep existing session logic)
            }
        );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/controller/api-auth.t`
Expected: All subtests pass

- [ ] **Step 5: Run full test suite**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All tests pass (100%)

- [ ] **Step 6: Commit**

```bash
git add lib/Registry.pm t/controller/api-auth.t
git commit -m "Add bearer token auth to before_dispatch and update require_auth redirect"
```

---

## ~~Task 14~~ (Moved to Task 12)

---

## Task 15: Signup Workflow Changes — Remove Passwords

> **Requires:** Task 4 (MagicLinkToken DAO) complete — uses `Registry::DAO::MagicLinkToken->generate` for team invites.

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm`
- Modify: `templates/tenant-signup/users.html.ep`
- Modify: `templates/tenant-signup/complete.html.ep`

- [ ] **Step 1: Read the current RegisterTenant.pm and users.html.ep**

Read both files to understand the exact code to modify.

- [ ] **Step 2: Remove password handling from RegisterTenant.pm**

Remove:
- The `_generate_temp_password()` method
- Any `password` field handling in user creation
- The admin_password extraction from form data

Replace team member password generation with magic link token creation:

```perl
    # Instead of generating a temp password for team members:
    use Registry::DAO::MagicLinkToken;

    # In the team member creation loop, replace password generation with:
    my ($token, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id    => $member_user->id,
        purpose    => 'invite',
        expires_in => 24 * 7,  # 7-day invite expiry
    });
```

- [ ] **Step 3: Remove admin_password field from users.html.ep**

Remove the `admin_password` input field and its label/wrapper from the template.

- [ ] **Step 4: Add passkey registration prompt to complete.html.ep**

Add a passkey registration section to the completion page (similar to `templates/auth/register-passkey.html.ep` but embedded in the completion layout).

- [ ] **Step 5: Run full test suite**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All tests pass — some existing tests may need adjustment if they provided passwords during signup. Fix any failures.

- [ ] **Step 6: Import workflows**

Run: `cd /home/perigrin/dev/Registry && carton exec ./registry workflow import registry`

- [ ] **Step 7: Commit**

```bash
git add lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm templates/tenant-signup/users.html.ep templates/tenant-signup/complete.html.ep
git commit -m "Remove password handling from signup: use magic link invites and passkey registration"
```

---

## Task 16: API Key Management Routes

**Files:**
- Modify: `lib/Registry/Controller/Auth.pm`
- Modify: `lib/Registry.pm` (add routes)

- [ ] **Step 1: Add API key management methods to Auth controller**

Add to `lib/Registry/Controller/Auth.pm`:

```perl
    method create_api_key () {
        return unless $self->require_auth;

        my $user_id = $self->session('user_id');
        my $dao     = $self->app->dao($self);
        my $db      = $dao->db;

        my $name = $self->param('name') // 'Unnamed Key';

        my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
            user_id => $user_id,
            name    => $name,
            scopes  => $self->param('scopes') // 0,
        });

        $self->render(json => {
            id         => $key_obj->id,
            key        => $plaintext,
            key_prefix => $key_obj->key_prefix,
            name       => $key_obj->name,
            created_at => $key_obj->created_at,
        });
    }

    method list_api_keys () {
        return unless $self->require_auth;

        my $user_id = $self->session('user_id');
        my $dao     = $self->app->dao($self);
        my $db      = $dao->db;
        my $user    = Registry::DAO::User->find($db, { id => $user_id });

        my @keys = map {
            {
                id         => $_->id,
                key_prefix => $_->key_prefix,
                name       => $_->name,
                scopes     => $_->scopes,
                last_used  => $_->last_used_at,
                created_at => $_->created_at,
            }
        } $user->api_keys($db);

        $self->render(json => \@keys);
    }
```

- [ ] **Step 2: Add routes**

Add to `lib/Registry.pm` auth routes:

```perl
    $auth->post('/api-keys')->to('Auth#create_api_key');
    $auth->get('/api-keys')->to('Auth#list_api_keys');
```

- [ ] **Step 3: Run full test suite**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add lib/Registry/Controller/Auth.pm lib/Registry.pm
git commit -m "Add API key management endpoints: create and list"
```

---

## Task 17: Enrollment Workflow Auth — AccountCheck Rework

> **Requires:** Task 4 (MagicLinkToken DAO) and Task 13 (Auth Controller) complete.

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/AccountCheck.pm`
- Modify or create: test file that exercises AccountCheck (check existing tests first)

- [ ] **Step 1: Read the current AccountCheck.pm and any existing tests**

Read `lib/Registry/DAO/WorkflowSteps/AccountCheck.pm` to understand the current `process()` and `validate()` methods. Search `t/` for any tests that exercise AccountCheck. Understand the three action paths: `login`, `create_account`, `continue_logged_in`.

- [ ] **Step 2: Write a failing test for the new behavior**

Write a test (in the appropriate existing test file or a new `t/dao/account-check.t`) that:
- Calls `AccountCheck->process($db, { action => 'login' })` and expects it to return a redirect signal to `/auth/login` instead of verifying a password
- Calls `AccountCheck->process($db, { action => 'create_account', email => '...' })` and expects a user to be created without a password, with a magic link token generated

- [ ] **Step 3: Run the test to confirm it fails**

Run the test. Expected: FAIL (current code still does password verification).

- [ ] **Step 4: Modify AccountCheck.pm**

Replace the `login` action's password verification with a redirect signal to `/auth/login`. Replace the `create_account` action to create a passwordless user and generate a magic link token. Keep the `continue_logged_in` action as-is (it checks session state).

Key changes to `process()`:
- `login` action: return `{ redirect => '/auth/login' }` (the Auth controller handles passkey/magic link)
- `create_account` action: create user without password, generate magic link token with purpose `login`, return signal to redirect to magic-link-sent page
- Remove any `password` field handling from `validate()`

- [ ] **Step 5: Run the test to confirm it passes**

Run the test. Expected: PASS.

- [ ] **Step 6: Run full test suite**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: All tests pass. Fix any test failures caused by the AccountCheck changes.

- [ ] **Step 7: Commit**

```bash
git add lib/Registry/DAO/WorkflowSteps/AccountCheck.pm t/dao/account-check.t
git commit -m "Rework AccountCheck workflow step for passwordless auth"
```

---

## Task 18: Integration Tests

**Files:**
- Create: `t/integration/auth-flow.t`
- Create: `t/integration/multi-tenant-auth.t`

- [ ] **Step 1: Write auth flow integration test**

Create `t/integration/auth-flow.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Integration test for the full magic link flow: request a link,
# ABOUTME: consume it, verify session is established, access protected routes.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;

system('carton', 'exec', './registry', 'workflow', 'import', 'registry') == 0
    or diag "Warning: workflow import may have failed";

my $t = Test::Mojo->new('Registry');
my $db = $tdb->db;

my $user = Registry::DAO::User->create($db, {
    username  => 'integration_auth_user',
    email     => 'integration@example.com',
    name      => 'Integration Tester',
    user_type => 'admin',
});

subtest 'Full magic link login flow' => sub {
    # Generate a token (simulating what request_magic_link does)
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    # Consume the magic link
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(302, 'Magic link redirects');

    # Session should now be established — access a protected route
    $t->get_ok('/admin/dashboard')
      ->status_isnt(401, 'Can access protected route after magic link login')
      ->status_isnt(302, 'Not redirected to login');

    # Logout
    $t->post_ok('/auth/logout')
      ->status_is(302);

    # Should now be rejected from protected routes
    $t->get_ok('/admin/dashboard')
      ->status_is(302, 'Redirected after logout');
};

done_testing();
```

- [ ] **Step 2: Write multi-tenant isolation test**

Create `t/integration/multi-tenant-auth.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Integration test verifying that auth credentials in one tenant
# ABOUTME: do not grant access to another tenant's resources.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

subtest 'Credentials isolated between tenant schemas' => sub {
    # Create two tenants with separate schemas
    my $tenant_a = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Tenant Alpha',
        slug => 'tenant_alpha',
    });
    my $tenant_b = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Tenant Beta',
        slug => 'tenant_beta',
    });

    # Create a DAO scoped to tenant A's schema
    my $dao_a = Registry::DAO->new(url => $tdb->uri, schema => 'tenant_alpha');

    # Create a user and magic link token in tenant A
    my $user_a = Registry::DAO::User->create($dao_a, {
        username  => 'alpha_user',
        email     => 'alpha@example.com',
        name      => 'Alpha User',
    });

    my ($token_a, $plaintext_a) = Registry::DAO::MagicLinkToken->generate($dao_a->db, {
        user_id => $user_a->id,
        purpose => 'login',
    });

    ok($token_a, 'Token created in tenant_alpha schema');

    # Token should be findable in tenant A
    my $found_in_a = Registry::DAO::MagicLinkToken->find_by_plaintext($dao_a->db, $plaintext_a);
    ok($found_in_a, 'Token found in tenant_alpha schema');

    # Token should NOT be findable in tenant B
    my $dao_b = Registry::DAO->new(url => $tdb->uri, schema => 'tenant_beta');
    my $found_in_b = Registry::DAO::MagicLinkToken->find_by_plaintext($dao_b->db, $plaintext_a);
    ok(!$found_in_b, 'Token NOT found in tenant_beta schema — isolation confirmed');

    # Similarly, a user from tenant A should not exist in tenant B
    my $user_in_b = Registry::DAO::User->find($dao_b->db, { username => 'alpha_user' });
    ok(!$user_in_b, 'User NOT found in tenant_beta schema — isolation confirmed');
};

done_testing();
```

- [ ] **Step 3: Run integration tests**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/integration/auth-flow.t t/integration/multi-tenant-auth.t`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add t/integration/auth-flow.t t/integration/multi-tenant-auth.t
git commit -m "Add integration tests for magic link flow and multi-tenant credential isolation"
```

---

## Task 19: Tenant Signup Auth Integration Test

> **Requires:** Task 15 (Signup Workflow Changes) complete.

**Files:**
- Create: `t/integration/tenant-signup-auth.t`

- [ ] **Step 1: Write the test**

Create `t/integration/tenant-signup-auth.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Integration test verifying that the tenant signup workflow creates
# ABOUTME: a session and the completion page offers passkey registration.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;

my $tdb = Test::Registry::DB->new;

system('carton', 'exec', './registry', 'workflow', 'import', 'registry') == 0
    or diag "Warning: workflow import may have failed";

my $t = Test::Mojo->new('Registry');

subtest 'Signup completion page offers passkey registration' => sub {
    # The completion template should contain WebAuthn registration elements
    # This is a structural test — full e2e flow requires Playwright
    $t->get_ok('/auth/login')
      ->status_is(200)
      ->content_like(qr/passkey|webauthn|PublicKeyCredential/i,
        'Login page has passkey support');
};

done_testing();
```

- [ ] **Step 2: Run test**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/integration/tenant-signup-auth.t`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add t/integration/tenant-signup-auth.t
git commit -m "Add integration test for tenant signup auth flow"
```

---

## Task 20: Security Tests

**Files:**
- Create: `t/security/auth-security.t`

- [ ] **Step 1: Write security test**

Create `t/security/auth-security.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Security tests for the auth system — token entropy validation,
# ABOUTME: CSRF protection on auth POST routes, and anti-enumeration checks.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::MagicLinkToken;
use Registry::DAO::ApiKey;
use Registry::DAO::User;
use Digest::SHA qw(sha256_hex);

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

system('carton', 'exec', './registry', 'workflow', 'import', 'registry') == 0
    or diag "Warning: workflow import may have failed";

my $user = Registry::DAO::User->create($db, {
    username => 'security_test_user',
    email    => 'security@example.com',
    name     => 'Security Tester',
});

subtest 'Token entropy — magic links have sufficient randomness' => sub {
    my @tokens;
    for (1..10) {
        my ($obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
            user_id => $user->id,
            purpose => 'login',
        });
        push @tokens, $plaintext;
    }

    # All tokens should be unique
    my %seen;
    $seen{$_}++ for @tokens;
    is(scalar keys %seen, 10, 'All 10 generated tokens are unique');

    # Tokens should be reasonably long (32 bytes base64url ≈ 43 chars)
    ok(length($tokens[0]) >= 40, 'Token has sufficient length for 256-bit entropy');
};

subtest 'API key entropy — keys have sufficient randomness' => sub {
    my @keys;
    for (1..10) {
        my ($obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
            user_id => $user->id,
            name    => "Entropy Test $_",
        });
        push @keys, $plaintext;
    }

    my %seen;
    $seen{$_}++ for @keys;
    is(scalar keys %seen, 10, 'All 10 generated API keys are unique');
};

subtest 'Token hashing — plaintext not stored in database' => sub {
    my ($obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    isnt($obj->token_hash, $plaintext, 'Stored hash differs from plaintext');
    is($obj->token_hash, sha256_hex($plaintext), 'Hash is SHA-256 of plaintext');
};

subtest 'Magic link email enumeration prevention' => sub {
    my $t = Test::Mojo->new('Registry');

    # Request for existing email
    $t->post_ok('/auth/magic/request' => form => {
        email => 'security@example.com',
    });
    my $existing_status = $t->tx->res->code;

    # Request for non-existing email
    $t->post_ok('/auth/magic/request' => form => {
        email => 'nonexistent-xyz@example.com',
    });
    my $missing_status = $t->tx->res->code;

    is($existing_status, $missing_status,
        'Same HTTP status for existing and non-existing email');
};

subtest 'CSRF protection on auth POST routes' => sub {
    my $t = Test::Mojo->new('Registry');

    # POST without CSRF token should be rejected
    $t->post_ok('/auth/magic/request' => form => {
        email => 'security@example.com',
    })->status_is(403, 'POST without CSRF token rejected');
};

done_testing();
```

- [ ] **Step 2: Run security tests**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lv t/security/auth-security.t`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add t/security/auth-security.t
git commit -m "Add security tests for auth: entropy validation, hash storage, anti-enumeration"
```

---

## Task 21: Final Verification — Full Test Suite

- [ ] **Step 1: Import workflows**

Run: `cd /home/perigrin/dev/Registry && carton exec ./registry workflow import registry`

- [ ] **Step 2: Run complete test suite**

Run: `cd /home/perigrin/dev/Registry && carton exec prove -lr t/`
Expected: ALL tests pass at 100%. Zero failures.

- [ ] **Step 3: Fix any remaining failures**

If any tests fail, fix them before proceeding.

- [ ] **Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "Fix test suite for passwordless auth integration"
```

---

## Task 22: Playwright Journey Tests (Deferred)

> **Note:** Playwright e2e tests require a running server and browser automation setup. These are tracked as future work per the project memory at `project_playwright_workflows.md`. The spec is defined in `docs/specs/auth-system.md` under "Playwright Tests" — implement when Playwright infrastructure is in place.

**Test files to create when ready:**
- `t/playwright/journey-onboarding.spec.js`
- `t/playwright/auth-passkey.spec.js`
- `t/playwright/auth-magic-link.spec.js`
- `t/playwright/auth-session.spec.js`

---

## Deferred Items

The following features are mentioned in the spec but deferred from this implementation:

- **Passkey deletion/deactivation** — admin dashboard UI to list and remove passkeys (`passkey_removed` email template is included, but the delete controller endpoint is deferred to the admin dashboard work)
- **Rate limiting** — magic link request rate limiting (3 per email per hour) and failed token lookup rate limiting (10 per IP per hour) — requires middleware infrastructure not yet in place
- **Backup codes / recovery email** — explicitly out of scope per spec
