# Magic Link Verification Flow

## Overview

Redesign the magic link consumption flow to prevent two real-world
vulnerabilities: link preview/prefetch token consumption, and wrong-device
login. Based on pitfalls documented at https://etodd.io/2026/03/22/magic-link-pitfalls/.

## Problem

The current flow uses `GET /auth/magic/:token` to directly consume the token
and establish a session. This has two issues:

1. **Prefetch consumption:** Email clients, browser prefetchers, and corporate
   proxies follow GET links automatically, consuming the token before the user
   clicks.

2. **Wrong device:** Clicking the link in an email app's embedded browser logs
   in that browser, not the user's primary browser where they initiated the
   login.

## Solution

Split token consumption into two phases: **verify** (GET, safe for
prefetchers) and **consume** (POST, requires user action). Add a polling
mechanism so the original browser tab can detect verification and complete
login automatically.

## Token Lifecycle

```
pending → verified (GET from email) → consumed (POST from either browser)
```

- **pending → verified:** `GET /auth/magic/:token` sets `verified_at` but does
  NOT set `consumed_at` or establish a session. Renders a confirmation page.
- **verified → consumed:** `POST /auth/magic/:token/complete` sets
  `consumed_at` and establishes the session.
- The confirmation page's "Sign In" button serves as a fallback when no
  polling tab exists (same-device flow).

**Race condition handling:** If both the polling tab and the confirmation
page "Sign In" button fire near-simultaneously, both POSTs target the same
`consumed_at` atomic UPDATE. One wins, one gets "Token already consumed."
The losing caller must receive a graceful "You're already signed in"
response, not an unhandled error. Both the plaintext and hash complete
endpoints must catch the `croak` and render the success state.

## Endpoints

All endpoints live under `/auth/magic/`. Routes are registered with
literal segments before placeholders to avoid ambiguity.

### Modified

**`GET /auth/magic/:token`** — Verify (not consume)

Looks up the token by plaintext. If valid, calls `verify()` to mark
`verified_at`. Renders `magic-link-confirm.html.ep` with a "Sign In" POST
button. If already consumed, shows "You're already signed in". If expired,
shows error.

### New

**`POST /auth/magic/:token/complete`** — Consume and establish session

Looks up the token by plaintext. Checks `verified_at` is set (for login
and recovery purpose tokens). Calls `consume()`. Establishes the session
with `user_id`, `tenant_schema`, `authenticated_at`. Redirects to `/` or
`/auth/register-passkey` for invites.

On "Token already consumed" from `consume()`, renders "You're already
signed in" (not an error).

**`GET /auth/magic/poll/:token_hash`** — Poll verification status

Returns JSON: `{ "status": "pending"|"verified"|"consumed"|"not_found" }`.
Uses the **token hash** (not plaintext) in the URL. Read-only. Polled by
the original browser tab every 2 seconds.

Note: expired and invalid tokens both return `"not_found"` to avoid
leaking token existence. The distinction between "never existed" and
"existed but expired" is not exposed.

**`POST /auth/magic/poll/:token_hash/complete`** — Consume via poll (by hash)

Looks up the token directly by hash. Same verification and consumption
logic as the plaintext complete endpoint. Called by the polling JS when
it detects verification. Requires CSRF token from the "check your email"
page.

On "Token already consumed", renders JSON `{ "ok": true }` (not an error).

### Route Registration Order

Routes must be registered with literal segments first:

```perl
$auth->get('/magic/poll/:token_hash')->to('Auth#magic_link_status');
$auth->post('/magic/poll/:token_hash/complete')->to('Auth#magic_link_complete_by_hash');
$auth->get('/magic/:token')->to('Auth#verify_magic_link');
$auth->post('/magic/:token/complete')->to('Auth#complete_magic_link');
```

The `/magic/poll/` prefix disambiguates the hash-based endpoints from the
plaintext endpoints. Mojolicious matches the literal `poll` segment before
falling through to the `:token` placeholder.

## Database Change

New column on `magic_link_tokens`:

```sql
ALTER TABLE magic_link_tokens ADD COLUMN IF NOT EXISTS verified_at timestamptz;
```

New sqitch migration: `magic-link-verification` (requires `passwordless-auth`).

The migration must propagate to tenant schemas using the same `DO $$ ... FOR s
IN SELECT slug FROM registry.tenants` pattern used in `passwordless-auth.sql`:

```sql
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
```

## DAO Changes

### New field

```perl
field $verified_at :param :reader = undef;
```

### New method: `verify($db)`

Atomic conditional UPDATE matching the `consume()` pattern. The pre-flight
checks (`croak "already verified"`, `croak "expired"`) are fast-path
optimizations only. The atomic `UPDATE WHERE verified_at IS NULL` is the
authoritative guard against concurrent verification.

```perl
method verify ($db) {
    # Fast-path checks (not authoritative -- the atomic UPDATE is the real guard)
    croak "Token already verified" if $verified_at;
    croak "Token has expired" if $self->is_expired;
    $db = $db->db if $db isa Registry::DAO;
    my $result = $db->update(
        $self->table,
        { verified_at => \'now()' },
        { id => $id, verified_at => undef },
        { returning => '*' }
    )->expand->hash;
    croak "Token already verified" unless $result;
    return blessed($self)->new($result->%*);
}
```

### Modified method: `consume($db)`

For `login` and `recovery` purpose tokens, require `verified_at` to be set
before consuming. This enforces the verify-then-consume flow. `invite` and
`verify_email` tokens skip this check since they don't use the polling flow.

### New class method: `find_by_hash($db, $hash)`

Look up a token directly by its stored hash. Returns the token object or
undef. Handles `$db isa Registry::DAO` unwrapping. Used by the poll status
and complete-by-hash endpoints.

```perl
sub find_by_hash ($class, $db, $hash) {
    $db = $db->db if $db isa Registry::DAO;
    return $class->find($db, { token_hash => $hash });
}
```

## Templates

### Modified: `templates/auth/magic-link-sent.html.ep`

Add a hidden form for CSRF token availability (the `after_render` hook
injects CSRF tokens into `<form>` elements), a data attribute for the
token hash, and polling JS:

```html
<div id="poll-target" data-token-hash="<%= $token_hash %>">
  <p>If an account exists for that email address, we have sent a magic link.</p>
  <p>The link will expire shortly.</p>
</div>

<!-- Hidden form so the after_render hook injects a CSRF token -->
<form id="poll-form" style="display:none"></form>
```

The JS polls `/auth/magic/poll/<hash>` every 2 seconds. On `verified`,
POSTs to `/auth/magic/poll/<hash>/complete` with the CSRF token from the
hidden form. Stops polling after 30 minutes or on `consumed`/`not_found`.

On network errors, the JS logs the error and continues polling (no
backoff for simplicity; the 2-second interval is already conservative).

### New: `templates/auth/magic-link-confirm.html.ep`

Rendered by `GET /auth/magic/:token` after verification:

- "Click to sign in" heading
- POST form with "Sign In" button targeting `/auth/magic/:token/complete`
- If already consumed: "You're already signed in" with link to `/`
- If expired: standard error message

This page is the **fallback for same-device login** and the **recovery path
when the original polling tab was closed**. It works on any device that has
the magic link URL.

## Polling Flow

1. User submits email on `/auth/login`
2. Server generates token, sends email, renders "check your email" page
   with `token_hash` embedded
3. "Check your email" page JS begins polling
   `/auth/magic/poll/<hash>` every 2s
4. User clicks magic link in email app (possibly different browser)
5. `GET /auth/magic/:token` verifies the token, renders confirmation page
6. **Cross-device path:** Polling detects `verified`, POSTs to
   `/auth/magic/poll/<hash>/complete`, session established in original browser
7. **Same-device path:** User clicks "Sign In" on confirmation page,
   POSTs to `/auth/magic/:token/complete`, session established in email
   browser

**Tab closed recovery:** If the user closes the original browser tab before
clicking the magic link, no polling occurs. When they click the link (on
any device), the confirmation page renders with the "Sign In" button. This
is the same-device fallback path and works correctly without polling.

## Rate Limiting

The polling endpoint `/auth/magic/poll/:hash` is under `/auth/` which the
existing `RateLimit.pm` applies the general limit (100 req/min) to, not the
stricter auth limit (10 req/min, which only matches paths containing `login`
or `password`). At 2-second intervals, a single user generates 30 req/min.
Multiple users behind the same NAT (e.g., 4 users = 120 req/min) could
exceed 100 req/min.

Add `/auth/magic/poll` to `@EXCLUDED_PREFIXES` in
`lib/Registry/Middleware/RateLimit.pm`. The endpoint is read-only, returns
no secret material, and the token hash provides no actionable information
to an attacker.

## Security

- **Prefetch safe:** GET only sets `verified_at`, never `consumed_at` or
  session. Prefetchers triggering verify is harmless (and actually helps
  the polling flow).
- **Token hash in URLs:** The hash identifies a token but cannot be used
  to construct the plaintext. An attacker who guesses a hash can only poll
  its status (pending/verified/consumed/not_found). No secret is revealed.
  Expired and invalid tokens both return `not_found` to avoid leaking
  token existence.
- **CSRF:** POST complete endpoints go through the CSRF hook. The "check
  your email" page includes a hidden `<form>` so the after_render hook
  injects a CSRF token. The confirmation page has a visible form with
  CSRF injected automatically. The poll-based complete JS reads CSRF from
  the hidden form's injected input.
- **Timeout:** Client-side polling stops after 30 minutes. Server-side
  token expiry (default 24h, tenant-configurable) is the authoritative
  limit.
- **Entropy:** Unchanged — 256 bits via `urandom(32)`.
- **Hash storage:** Unchanged — only SHA-256 hash stored, never plaintext.
- **Single use:** Unchanged — atomic `UPDATE WHERE consumed_at IS NULL`.
- **Atomic guards:** Both `verify()` and `consume()` use atomic conditional
  UPDATEs as the authoritative concurrency guard. Pre-flight in-memory
  checks are optimizations only — not the primary defense.

## Testing

### Unit tests (`t/dao/magic-link-token.t`)
- `verify()` sets `verified_at`
- `verify()` is atomic (concurrent calls, only first succeeds)
- `consume()` requires `verified_at` for login tokens
- `consume()` requires `verified_at` for recovery tokens
- `consume()` does not require `verified_at` for invite/verify_email tokens
- `find_by_hash()` returns correct token
- `find_by_hash()` returns undef for unknown hash

### Controller tests (`t/controller/auth.t`)
- `GET /auth/magic/:token` renders confirmation page (does not set session)
- `GET /auth/magic/:token` with expired token shows error
- `GET /auth/magic/:token` with consumed token shows "already signed in"
- `POST /auth/magic/:token/complete` establishes session
- `POST /auth/magic/:token/complete` requires prior verification for login
- `POST /auth/magic/:token/complete` on already-consumed token shows
  "already signed in" (graceful, not error)
- `GET /auth/magic/poll/:hash` returns correct status for each state
- `POST /auth/magic/poll/:hash/complete` establishes session after verification
- `POST /auth/magic/poll/:hash/complete` on already-consumed token returns
  `{ ok: true }` (graceful, not error)

### Integration tests (`t/integration/auth-flow.t`)
- Full cross-device flow: request → verify → poll detects → complete
- Full same-device flow: request → verify → click "Sign In"
- Tab-closed recovery: request → close tab → verify on different device →
  click "Sign In" on confirmation page
- Prefetch scenario: GET verify twice (idempotent or second returns
  already-verified page)
- Double-consume race: verify → two simultaneous POSTs → one succeeds,
  one gets "already signed in"
- Consumed token: poll returns "consumed", confirmation shows "already
  signed in"

### Playwright tests (`t/playwright/auth-journeys.spec.js`)
- Update existing magic link tests for the new two-step flow
- Add polling test: request magic link, verify via direct navigation,
  confirm original page detects verification (requires two browser
  contexts or direct API seeding of verified state)

## Deployment

The database migration and code changes must be deployed atomically (same
release). If deployed separately:

- **Migration first, code second:** In-flight login tokens will not have
  `verified_at`, but the old `consume_magic_link` route still calls
  `consume()` directly. This works because `consume()` only enforces
  `verified_at` for login tokens when the new code is deployed.
- **Code first, migration second:** The `verified_at` column does not
  exist, so `verify()` will fail. This order is not safe.

Recommended: deploy migration and code together in a single release.

## Backward Compatibility

Existing unconsumed tokens in the DB will not have `verified_at` set.
When the new code is deployed:

- **Login tokens:** The new `GET /auth/magic/:token` calls `verify()` which
  sets `verified_at`. Then `POST .../complete` calls `consume()` which
  checks `verified_at`. This works for all tokens regardless of when they
  were created.
- **Recovery tokens:** Same as login tokens — `verified_at` enforced.
- **Invite tokens:** `consume()` does not check `verified_at`. Unchanged.
- **Verify_email tokens:** `consume()` does not check `verified_at`. Unchanged.

The email magic link URL (`/auth/magic/:token`) remains the same — the
behavior changes from direct consumption to verification + confirmation.
No email template changes needed.
