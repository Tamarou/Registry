# Authentication System Specification

## Overview

Registry replaces password-based authentication with a passwordless system built
on **WebAuthn passkeys** (primary) and **magic links** (fallback/bootstrap). API
access uses **bearer tokens**. No passwords are stored or accepted anywhere in
the system.

Authentication credentials live in the **tenant schema**, not a global table.
Each tenant is structurally self-contained — if a tenant extracts to its own
Registry instance, it carries all user credentials with it. The `registry`
schema is simply the root tenant (Tiny Art Empires), not a privileged global
store.

## Personas and Auth Flows

### Jordan (Tenant Owner)

1. Visits `tinyartempire.com`, starts `tenant-signup` workflow
2. Completes profile, team setup (no password field), pricing, review, payment
3. Session cookie is set when the workflow begins — Jordan stays logged in
   throughout
4. On the completion page, prompted to register a passkey ("Secure your account
   with quick login")
5. Email verification is sent during the `users` step — non-blocking, but
   gates delivery of team member invitations

### Morgan (Admin/Program Manager)

1. Jordan adds Morgan during signup (team members section of `users` step)
2. Morgan's user record is created in the tenant schema with `invite_pending`
   flag
3. Once Jordan verifies their email, Morgan receives a **single-use magic link**
   (24-hour default expiry, configurable per tenant)
4. Morgan clicks the link, establishes a session, and is immediately prompted to
   register a passkey
5. Subsequent logins use passkey; magic link available as fallback

### Nancy (Parent)

1. Visits the tenant's domain to enroll her child
2. Enrollment workflow includes a "sign in or create account" step
3. If new: provides email, creates account, registers passkey
4. If returning: authenticates via passkey (or requests magic link)
5. Continues through enrollment workflow after authentication

### API Consumers

1. Authenticated user generates an API key from their dashboard
2. API requests include `Authorization: Bearer <key>` header
3. Same user identity, same role/permission checks as browser sessions

## Session Management

- **Transport**: Mojolicious signed-cookie sessions (no server-side session
  store for pre-alpha)
- **Default duration**: 4 hours of inactivity
- **"Remember me"**: 30 days
- **Session data**: `user_id`, `tenant_schema`, `remember_me` flag,
  `authenticated_at` timestamp
- **Revocation**: Not supported server-side in pre-alpha. Admin can deactivate
  user accounts, which causes the `before_dispatch` hook to reject the session
  on next request.
- **Logout**: Clears the session cookie

## Data Model

All tables live in the **tenant schema**. Migrations must propagate to all
existing tenant schemas (same pattern as `add-user-fields-for-family.sql`).

### `passkeys` Table

```sql
CREATE TABLE IF NOT EXISTS passkeys (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id bytea NOT NULL UNIQUE,
    public_key bytea NOT NULL,
    sign_count bigint NOT NULL DEFAULT 0,
    device_name text,  -- user-friendly label, e.g. "Morgan's MacBook"
    created_at timestamptz DEFAULT now(),
    last_used_at timestamptz
);

CREATE INDEX idx_passkeys_user_id ON passkeys(user_id);
CREATE INDEX idx_passkeys_credential_id ON passkeys(credential_id);
```

### `magic_link_tokens` Table

```sql
CREATE TABLE IF NOT EXISTS magic_link_tokens (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,  -- SHA-256 hash, never store plaintext
    purpose text NOT NULL CHECK (purpose IN ('login', 'invite', 'recovery')),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_magic_link_tokens_user_id ON magic_link_tokens(user_id);
CREATE INDEX idx_magic_link_tokens_token_hash ON magic_link_tokens(token_hash);
```

### `api_keys` Table

```sql
CREATE TABLE IF NOT EXISTS api_keys (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_hash text NOT NULL UNIQUE,  -- SHA-256 hash, never store plaintext
    key_prefix text NOT NULL,  -- first 8 chars for identification (e.g. "rk_live_a")
    name text NOT NULL,  -- user-friendly label
    scopes bigint NOT NULL DEFAULT 0,  -- bitvector for permissions
    expires_at timestamptz,  -- NULL = no expiry
    last_used_at timestamptz,
    created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_api_keys_user_id ON api_keys(user_id);
CREATE INDEX idx_api_keys_key_hash ON api_keys(key_hash);
```

### `users` Table Changes

- `passhash` column: Make nullable (`ALTER TABLE users ALTER COLUMN passhash
  DROP NOT NULL`). Leave the column in place — no data migration needed since
  new users won't have passwords. Existing `Crypt::Passphrase` code can remain
  dormant.
- Add `email_verified_at timestamptz` column to `users` table (currently email
  lives only in `user_profiles`, but verification status belongs on the identity)
- Add `invite_pending boolean DEFAULT false` column if not already present

### Tenant Configuration

The `tenants` table (or tenant config) needs:

- `canonical_domain text` — used as WebAuthn relying party ID and magic link
  URL base. Defaults to `<slug>.tinyartempire.com`. Updated when a domain alias
  is configured.
- `magic_link_expiry_hours integer DEFAULT 24` — configurable per tenant

## WebAuthn (Passkeys) Implementation

### Relying Party Configuration

- **RP ID**: Tenant's canonical domain (e.g., `dance-stars.com` or
  `dance-stars.tinyartempire.com`)
- **RP Name**: Tenant's display name from their profile
- **RP Origin**: `https://<canonical_domain>`
- When a tenant transitions from subdomain to custom domain, existing passkeys
  become invalid and users must re-register (magic link fallback handles this
  gracefully)

### Registration Flow

1. Server generates challenge, stores in session
2. Browser calls `navigator.credentials.create()` with challenge and RP config
3. Browser returns attestation response
4. Server verifies attestation, extracts credential ID and public key
5. Server stores in `passkeys` table with user-provided device name

### Authentication Flow

1. Server generates challenge, stores in session
2. Server sends list of `allowCredentials` (credential IDs for the user, if
   known — or empty for discoverable credentials)
3. Browser calls `navigator.credentials.get()` with challenge
4. Browser returns assertion response
5. Server verifies assertion signature against stored public key
6. Server verifies and updates `sign_count` (replay protection)
7. Server sets session cookie

### Discoverable Credentials

Support discoverable credentials (resident keys) so the user doesn't need to
enter their email/username first. The browser's credential picker shows
available passkeys for the domain. This enables the ideal UX: visit site →
biometric prompt → logged in.

## Magic Links Implementation

### Token Generation

1. Generate 32 bytes of cryptographic randomness (`Crypt::URandom`)
2. Base64url-encode for the URL token
3. SHA-256 hash for storage in `magic_link_tokens.token_hash`
4. The plaintext token appears only in the email link, never stored

### Link Format

```
https://<tenant_domain>/auth/magic/<base64url_token>
```

### Verification Flow

1. User clicks link
2. Server extracts token from URL, computes SHA-256 hash
3. Looks up `magic_link_tokens` by `token_hash` in the tenant schema
4. Validates: not expired, not consumed
5. Marks token as consumed (`consumed_at = now()`)
6. Sets session cookie for the associated user
7. Redirects to appropriate destination (invite → passkey registration,
   login → dashboard, etc.)

### Rate Limiting

- Magic link requests: 3 per email per hour per tenant
- Failed token lookups: 10 per IP per hour (prevents enumeration)

## API Key Implementation

### Key Generation

1. Generate 32 bytes of cryptographic randomness
2. Format: `rk_<environment>_<base64url_random>` (e.g., `rk_live_a1b2c3...`)
3. Store SHA-256 hash in `api_keys.key_hash`
4. Store first 8 characters in `api_keys.key_prefix` for identification
5. **Display the full key exactly once** at creation time — it cannot be
   retrieved after

### Authentication Flow

1. Extract token from `Authorization: Bearer <token>` header
2. Compute SHA-256 hash
3. Look up `api_keys` by `key_hash` in the tenant schema (tenant determined
   from subdomain/header as usual)
4. Validate: not expired
5. Update `last_used_at`
6. Load associated user, populate `current_user` in stash

### Scopes (Bitvector)

```
Bit 0 (1):   read        - Read access to tenant data
Bit 1 (2):   write       - Create/update records
Bit 2 (4):   delete      - Delete records
Bit 3 (8):   admin       - Administrative operations
Bit 4 (16):  enrollment  - Enrollment management
Bit 5 (32):  financial   - Payment and financial data
Bit 6 (64):  reporting   - Reports and analytics
Bit 7 (128): webhooks    - Webhook management
```

Scope definitions will expand as the API surface grows. A scope of `0` means
no restrictions (full access — backward compatible default for admin-generated
keys). Scope checks use bitwise AND: `($key->scopes & $required_scope) ==
$required_scope`.

## Changes to Existing Code

### `lib/Registry.pm`

**`before_dispatch` hook** (lines 172–195): Extend to support three auth
methods in priority order:

1. **Bearer token**: Check `Authorization` header → look up API key in tenant
   schema → populate `current_user`
2. **Session cookie**: Existing logic, but look up user in **tenant schema**
   (not the global `registry` DAO) based on `tenant_schema` stored in session
3. **No auth**: Continue as unauthenticated

The tenant must be resolved **before** auth, since credentials live in the
tenant schema. Current tenant resolution (subdomain/header/cookie) already
runs first — this ordering is correct.

**`require_auth` helper** (lines 200–219): Change the unauthenticated redirect
from `/user-creation` to `/auth/login`.

**Session writing**: Add `$c->session(user_id => $user->id, tenant_schema =>
$tenant)` at each authentication success point (passkey verification, magic
link consumption, and during signup workflow).

### `lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm`

- Remove password handling from user creation
- Remove `_generate_temp_password()` method
- Create users without `passhash`
- For team members: create `magic_link_tokens` record with purpose `invite`
  instead of generating temp passwords
- Queue invitation email delivery (gated on Jordan's email verification)

### `templates/tenant-signup/users.html.ep`

- Remove the `admin_password` field (lines 37–41)
- Remove `required` from the removed field
- Add brief explanation: "You'll set up secure login after signup"

### `templates/tenant-signup/complete.html.ep`

- Add passkey registration prompt with WebAuthn JavaScript
- Include "Skip for now" option (user can register passkey later via magic
  link on return)

### `lib/Registry/DAO/User.pm`

- `passhash` becomes optional in `create` — don't require `password` param
- Keep `Crypt::Passphrase` code in place but dormant (no active callers)
- Add methods: `passkeys`, `magic_link_tokens`, `api_keys` (relationship
  accessors)

## New Code

### Routes

```
GET  /auth/login                  → Login page (passkey prompt + magic link request)
POST /auth/magic/request          → Generate and send magic link
GET  /auth/magic/:token           → Consume magic link, set session
POST /auth/webauthn/register/begin   → Start passkey registration (returns challenge)
POST /auth/webauthn/register/complete → Complete passkey registration
POST /auth/webauthn/auth/begin       → Start passkey authentication (returns challenge)
POST /auth/webauthn/auth/complete    → Complete passkey authentication
POST /auth/logout                 → Clear session
GET  /auth/verify-email/:token    → Verify email address
```

All `/auth/*` routes are unprotected (no `require_auth`).

### New DAO Classes (Object::Pad feature classes)

All new classes use the project's standard Object::Pad pattern:

```perl
use 5.34.0;
use experimental 'signatures';
use Object::Pad;

class Registry::DAO::Passkey :isa(Registry::DAO::Base) { ... }
```

- `Registry::DAO::Passkey` — CRUD for passkeys table, sign count tracking
- `Registry::DAO::MagicLinkToken` — create, find_by_hash, consume, expired?
- `Registry::DAO::ApiKey` — create (returns plaintext once), find_by_hash,
  check_scope (bitvector AND)

### WebAuthn Library (`Registry::Auth::WebAuthn`)

Custom implementation built from spec using low-level crypto primitives. No
dependency on `Authen::WebAuthn` — that module lacks discoverable credential
support, has incomplete validation, and depends on Mouse. Our implementation
uses Object::Pad feature classes throughout.

```perl
class Registry::Auth::WebAuthn {
    field $rp_id :param :reader;
    field $rp_name :param :reader;
    field $origin :param :reader;

    # Registration
    method generate_registration_options($user_id, $user_name, $user_display_name, %opts);
    method verify_registration_response($challenge, $client_data_json, $attestation_object);

    # Authentication (supports discoverable credentials)
    method generate_authentication_options(%opts);  # allow_credentials optional
    method verify_authentication_response($challenge, $client_data_json,
        $authenticator_data, $signature, $credential_public_key, $stored_sign_count);
}
```

Supporting classes:

- `Registry::Auth::WebAuthn::Challenge` — challenge generation and
  session storage
- `Registry::Auth::WebAuthn::COSE` — COSE key parsing (decode CBOR
  public keys to `Crypt::PK::ECC` / `Crypt::PK::RSA` objects)
- `Registry::Auth::WebAuthn::AuthenticatorData` — parse the 37+ byte
  authenticator data structure (rpIdHash, flags, signCount, attested
  credential data)

The implementation covers WebAuthn Level 2 for three algorithms:

- **ES256** — P-256 ECDSA (most common, used by platform authenticators)
- **RS256** — RSA with SHA-256 (legacy compatibility)
- **EdDSA** — Ed25519 (modern authenticators, via `Crypt::PK::Ed25519`)

### New Controller (Object::Pad feature class)

- `Registry::Controller::Auth` — handles all `/auth/*` routes

### New Workflow Step

- `Registry::DAO::WorkflowSteps::AccountCheck` — already exists but needs
  rework: replace password verification with "sign in via passkey or request
  magic link" for enrollment workflow integration

### Frontend JavaScript

- WebAuthn registration and authentication calls
  (`navigator.credentials.create/get`)
- No external JS dependencies required — WebAuthn is a browser-native API
- Progressive enhancement: detect `window.PublicKeyCredential` support,
  fall back to magic-link-only if absent

### CPAN Dependencies

New dependencies (added to `cpanfile`):

- `CBOR::XS` — CBOR decoding for WebAuthn attestation objects and COSE keys
- `CryptX` — provides `Crypt::PK::ECC` (ES256 signature verification),
  `Crypt::PK::RSA` (RS256), and `Crypt::Digest::SHA256`
- `Crypt::URandom` — cryptographic random bytes for challenges and tokens
- `MIME::Base64` (core) — base64url encoding for WebAuthn and tokens
- `Digest::SHA` (core) — SHA-256 hashing for token storage

Not needed (removed from earlier draft):

- ~~`Authen::WebAuthn`~~ — replaced by `Registry::Auth::WebAuthn` (custom,
  Object::Pad, fewer deps, full discoverable credential support)
- ~~`Crypt::OpenSSL::X509`~~ — not needed without attestation verification
- ~~`Net::SSLeay`~~ — already a Mojolicious transitive dep, not directly used
- ~~`Mouse`~~ — avoided entirely by using Object::Pad

## Email Verification Flow

1. During signup `users` step, when Jordan provides their email:
   - Generate verification token (same mechanism as magic links, purpose
     `verify_email` — or reuse magic_link_tokens with a `verification` purpose)
   - Send verification email with link
2. Verification link: `https://<tenant_domain>/auth/verify-email/<token>`
3. On click: mark `users.email_verified_at = now()`
4. Check: before sending team member invitation magic links, verify
   `inviter.email_verified_at IS NOT NULL`
5. Post-signup, show persistent banner if email unverified:
   "Verify your email to activate team invitations"

## Error Handling

### Passkey Errors

| Scenario | User-Facing Behavior |
|----------|---------------------|
| Browser doesn't support WebAuthn | Hide passkey option, show magic link only |
| User cancels passkey prompt | Show "Try again" + magic link fallback |
| Credential not found in DB | "This passkey isn't recognized. Try a magic link instead." |
| Sign count regression (replay) | Reject auth, flag credential, prompt magic link |
| Registration fails | "Setup failed. You can try again or use email login." |

### Magic Link Errors

| Scenario | User-Facing Behavior |
|----------|---------------------|
| Token expired | "This link has expired. Request a new one." with request form |
| Token already used | "This link has already been used. Request a new one." |
| Token not found | Generic "Invalid link" (don't leak whether token existed) |
| Rate limited | "Too many requests. Please wait before requesting another link." |
| Email not found in tenant | Generic "If this email exists, a link has been sent." (don't leak) |

### API Key Errors

| Scenario | HTTP Response |
|----------|--------------|
| Missing/malformed Authorization header | 401 `{"error": "Authentication required"}` |
| Invalid key | 401 `{"error": "Invalid API key"}` |
| Expired key | 401 `{"error": "API key expired"}` |
| Insufficient scope | 403 `{"error": "Insufficient permissions"}` |

### General

- All auth failure responses must be constant-time (prevent timing attacks on
  token/key lookups)
- Never reveal whether an email exists in error messages to unauthenticated
  users
- Log all auth events (success and failure) with IP, user agent, timestamp,
  and tenant

## Account Recovery

For pre-alpha, recovery is:

1. **Primary**: User requests a magic link to their registered email
2. **Last resort**: Contact tenant admin, who can reset credentials from admin
   dashboard (deactivate old passkeys, generate new magic link)
3. **Future**: Backup codes, recovery email — out of scope for this spec

Admin credential reset requires:

- Admin dashboard UI to list a user's passkeys and deactivate them
- Admin action to generate a magic link on behalf of a user
- Audit log entry for all admin credential actions

## Domain Alias Considerations

- Tenant's `canonical_domain` is used as WebAuthn RP ID
- When a tenant configures a domain alias (`dance-stars.com`), update
  `canonical_domain`
- Existing passkeys registered under the old domain become invalid
- Users will be prompted to re-register passkeys via magic link fallback
- Magic links use the `canonical_domain` for URL generation, so they work
  immediately after domain change
- Consider: during domain transition, briefly accept passkeys from **both**
  domains? This adds complexity and may not be worth it for pre-alpha.

## Testing Plan

### Unit Tests (`t/dao/`)

- `t/dao/passkey.t` — CRUD operations, sign count updates, cascade delete
- `t/dao/magic-link-token.t` — creation, hash verification, consumption,
  expiry, single-use enforcement
- `t/dao/api-key.t` — creation, hash verification, scope bitvector checks,
  expiry, prefix storage
- `t/dao/user-auth.t` — user creation without password, relationship accessors

### Controller Tests (`t/controller/`)

- `t/controller/auth.t` — all `/auth/*` routes:
  - Magic link request (valid email, unknown email, rate limiting)
  - Magic link consumption (valid, expired, already used, invalid)
  - WebAuthn registration begin/complete (mock challenge/response)
  - WebAuthn authentication begin/complete
  - Logout
  - Email verification
- `t/controller/api-auth.t` — bearer token authentication:
  - Valid key, invalid key, expired key, scope enforcement
  - Interaction with `require_auth` and `require_role`

### Integration Tests (`t/integration/`)

- `t/integration/auth-flow.t` — full magic link flow: request → email (check
  outbox/log) → consume → session established → protected route accessible
- `t/integration/tenant-signup-auth.t` — signup workflow creates session,
  completion step offers passkey registration, team member tokens created
- `t/integration/multi-tenant-auth.t` — credentials in one tenant don't
  grant access to another tenant

### Security Tests (`t/security/`)

- `t/security/auth-security.t`:
  - Timing-safe token comparison
  - Rate limiting on magic link requests
  - Rate limiting on failed token lookups
  - Session fixation prevention
  - CSRF protection on all auth POST routes
  - Token entropy validation (sufficient randomness)
  - Cross-tenant credential isolation

### Playwright Tests (`t/playwright/`)

These are the journey tests that motivated this spec:

- `t/playwright/journey-onboarding.spec.js` — Jordan signs up → registers
  passkey → Morgan receives invite → Morgan registers passkey → Morgan
  creates program/session → Nancy enrolls → Nancy registers passkey
- `t/playwright/auth-passkey.spec.js` — passkey registration and
  authentication UX, browser compatibility, fallback behavior
- `t/playwright/auth-magic-link.spec.js` — magic link request UX, error
  states, expired link handling
- `t/playwright/auth-session.spec.js` — session expiry, remember me,
  logout, re-auth UX

## Implementation Order

1. **Database migrations** — `passkeys`, `magic_link_tokens`, `api_keys`
   tables; `users.passhash` nullable; `users.email_verified_at` column;
   tenant `canonical_domain`
2. **DAO classes** — `Passkey`, `MagicLinkToken`, `ApiKey` with full test
   coverage (Object::Pad feature classes, `:isa(Registry::DAO::Base)`)
3. **WebAuthn library** — `Registry::Auth::WebAuthn` and supporting classes
   (`Challenge`, `COSE`, `AuthenticatorData`). Object::Pad feature classes.
   Built on `CBOR::XS` + `CryptX`. Full unit test coverage against known
   WebAuthn test vectors before integration.
4. **Magic links** — token generation, email sending (via existing
   `Registry::DAO::Notification`), consumption, controller routes. Add new
   templates to `Registry::Email::Template`. This unblocks all auth flows
   since magic links bootstrap first sessions.
5. **Session management** — `before_dispatch` rewrite, session writing,
   `require_auth` redirect update, logout
6. **WebAuthn controller integration** — registration and authentication
   flows, frontend JS, `/auth/webauthn/*` routes
7. **Signup workflow changes** — remove password field, add passkey
   registration to completion page, email verification, invitation token
   generation
8. **API keys** — generation, bearer token auth in `before_dispatch`, scope
   checking, admin dashboard UI
9. **Enrollment workflow auth** — "sign in or create account" step with
   passkey/magic link integration
10. **Playwright journey tests** — full onboarding journey with all three
    personas (Jordan → Morgan → Nancy)

## Resolved Decisions

1. **Email delivery**: Already implemented. `Registry::DAO::Notification` +
   `Email::Sender::Simple` handles delivery. `Registry::Email::Template`
   handles rendering. Just need new templates for auth emails.
2. **Passkey attestation**: Accept `none`. No hardware attestation required.
   Consumer-facing app; attestation reduces compatibility for no meaningful
   security gain.
3. **Multiple passkeys per user**: Yes. Users can register multiple passkeys
   (phone + laptop + security key). The `passkeys` table supports multiple
   rows per `user_id`.
4. **API key management**: Any authenticated user can generate keys. Keys
   cannot exceed the user's own role permissions — scope bitvector is
   intersected with the user's role capabilities at validation time.
5. **WebAuthn library**: Custom implementation (`Registry::Auth::WebAuthn`)
   using Object::Pad feature classes, built on `CBOR::XS` + `CryptX`. Avoids
   `Authen::WebAuthn` due to: missing discoverable credential support,
   incomplete spec validation, Mouse dependency, bus-factor-1 maintenance.

### Email Infrastructure (Existing)

Email delivery already exists in the codebase:

- `Email::Simple` and `Email::Sender::Simple` in cpanfile
- `Registry::DAO::Notification` — `send_email` method handles delivery
- `Registry::Email::Template` — HTML/text email renderer with inline CSS

New email templates needed (added to `Registry::Email::Template`):

- `magic_link_login` — "Click to sign in" with link and expiry notice
- `magic_link_invite` — "You've been invited to [tenant]" with link, role,
  and expiry notice
- `email_verification` — "Verify your email address" with link
- `passkey_registered` — confirmation that a new passkey was added (security
  notification)
- `passkey_removed` — confirmation that a passkey was deactivated (security
  notification)

## Resolved Decisions (continued)

6. **Domain alias mechanics**: Resolved in separate spec
   (`docs/specs/custom-domains.md`). CNAME-based, self-service, 1 domain per
   tenant, managed via Render API.
7. **EdDSA support**: Included in initial implementation. The WebAuthn library
   (`Registry::Auth::WebAuthn`) supports ES256 (P-256 ECDSA), RS256, and
   EdDSA (Ed25519) from day one. `CryptX` provides `Crypt::PK::Ed25519` for
   signature verification. Test vectors for all three algorithms required.
