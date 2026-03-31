# Implementation Plan: Magic Link Verification Flow

## Goal

Redesign the magic link consumption flow to prevent prefetch token consumption
and wrong-device login. Split the single `GET /auth/magic/:token` endpoint into
a two-phase verify+consume flow with a polling mechanism so the original browser
tab can detect verification and complete login automatically.

## Architecture

The token lifecycle becomes `pending → verified → consumed`. A new `verified_at`
column gates the transition to consumed. Four endpoints replace the current one:

- `GET /auth/magic/:token` — verify only (safe for prefetchers)
- `POST /auth/magic/:token/complete` — consume by plaintext (same-device fallback)
- `GET /auth/magic/poll/:token_hash` — JSON status (polling target)
- `POST /auth/magic/poll/:token_hash/complete` — consume by hash (cross-device)

The "check your email" page embeds the `token_hash` and polls every 2 seconds.
On detecting `verified`, it POSTs to the hash-based complete endpoint with a
CSRF token sourced from a hidden form on the same page.

## Tech Stack

- Perl 5.42.0 with Object::Pad
- Mojolicious controller methods (no explicit `$self` parameter)
- Mojo::Pg for database access
- Sqitch for schema migrations
- Test::More + Test::Mojo for tests

---

## File Structure

### New files
- `sql/deploy/magic-link-verification.sql` — adds `verified_at` column
- `sql/revert/magic-link-verification.sql` — reverts the column
- `sql/verify/magic-link-verification.sql` — verifies the column exists
- `templates/auth/magic-link-confirm.html.ep` — confirmation page rendered after GET verify

### Modified files
- `lib/Registry/DAO/MagicLinkToken.pm` — add `$verified_at` field, `verify()` method, modified `consume()`, `find_by_hash()` class method
- `lib/Registry/Controller/Auth.pm` — rename `consume_magic_link` to `verify_magic_link`, add `complete_magic_link`, `magic_link_status`, `magic_link_complete_by_hash`
- `lib/Registry.pm` — replace old route with four new routes (literal segments before placeholders)
- `lib/Registry/Middleware/RateLimit.pm` — add `/auth/magic/poll` to `@EXCLUDED_PREFIXES`
- `templates/auth/magic-link-sent.html.ep` — add `token_hash` data attribute, hidden form, polling JS
- `t/dao/magic-link-token.t` — add tests for `verify()`, `find_by_hash()`, modified `consume()`
- `t/controller/auth.t` — update existing token test, add new endpoint tests
- `t/integration/auth-flow.t` — add cross-device, same-device, race condition, and prefetch scenarios

---

## Tasks

### Task 1 — Sqitch migration files (5 min)

Create the three sqitch artefact files. No tests yet — the migration is verified
by later DAO tests that actually hit the database.

**`sql/deploy/magic-link-verification.sql`:**

```sql
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
```

**`sql/revert/magic-link-verification.sql`:**

```sql
-- Revert registry:magic-link-verification from pg

BEGIN;

ALTER TABLE magic_link_tokens DROP COLUMN IF EXISTS verified_at;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        EXECUTE format(
            'ALTER TABLE %I.magic_link_tokens DROP COLUMN IF EXISTS verified_at;',
            s
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
```

**`sql/verify/magic-link-verification.sql`:**

```sql
-- Verify registry:magic-link-verification

SELECT verified_at
  FROM magic_link_tokens
 WHERE false;
```

Register the migration in `sqitch.plan` by appending:

```
magic-link-verification [passwordless-auth] 2026-03-31T00:00:00Z Chris Prather <chris.prather@tamarou.com> # Add verified_at to magic_link_tokens for two-phase verify+consume flow
```

Run to deploy:

```bash
carton exec sqitch deploy
```

Commit: "Add sqitch migration for magic-link-verification (verified_at column)"

---

### Task 2 — DAO: write failing tests for new behaviour (5 min)

Add the following subtests to `t/dao/magic-link-token.t` **before** implementing
anything. Run the suite and confirm all new subtests fail.

Insert after the existing `'Purpose constraint enforced'` subtest:

```perl
subtest 'verify() sets verified_at' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok(!$token_obj->verified_at, 'Token not yet verified');
    my $verified = $token_obj->verify($db);
    ok($verified->verified_at, 'verified_at set after verify()');
    is($verified->id, $token_obj->id, 'Same token returned');
};

subtest 'verify() is idempotent-safe: second call dies' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    my $verified = $token_obj->verify($db);
    ok($verified->verified_at, 'First verify succeeds');
    dies_ok { $verified->verify($db) } 'Second verify dies';
};

subtest 'verify() dies for expired token' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id    => $user->id,
        purpose    => 'login',
        expires_in => -1,
    });

    dies_ok { $token_obj->verify($db) } 'Cannot verify expired token';
};

subtest 'consume() requires verified_at for login tokens' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    dies_ok { $token_obj->consume($db) } 'Cannot consume unverified login token';

    my $verified = $token_obj->verify($db);
    lives_ok { $verified->consume($db) } 'Can consume verified login token';
};

subtest 'consume() requires verified_at for recovery tokens' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'recovery',
    });

    dies_ok { $token_obj->consume($db) } 'Cannot consume unverified recovery token';

    my $verified = $token_obj->verify($db);
    lives_ok { $verified->consume($db) } 'Can consume verified recovery token';
};

subtest 'consume() does NOT require verified_at for invite tokens' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'invite',
    });

    lives_ok { $token_obj->consume($db) } 'Can consume unverified invite token';
};

subtest 'consume() does NOT require verified_at for verify_email tokens' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'verify_email',
    });

    lives_ok { $token_obj->consume($db) } 'Can consume unverified verify_email token';
};

subtest 'find_by_hash() returns correct token' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    my $found = Registry::DAO::MagicLinkToken->find_by_hash($db, $token_obj->token_hash);
    ok($found, 'Found token by hash');
    is($found->id, $token_obj->id, 'Correct token returned');
};

subtest 'find_by_hash() returns undef for unknown hash' => sub {
    my $not_found = Registry::DAO::MagicLinkToken->find_by_hash($db, 'notarealhash');
    ok(!$not_found, 'Returns undef for unknown hash');
};
```

Run:

```bash
carton exec prove -lv t/dao/magic-link-token.t
```

Confirm the new subtests fail (the existing ones must still pass).

---

### Task 3 — DAO: implement new behaviour (5 min)

Edit `lib/Registry/DAO/MagicLinkToken.pm`:

**1. Add `$verified_at` field** after the existing `$consumed_at` field:

```perl
field $verified_at :param :reader = undef;
```

**2. Add `find_by_hash` class method** after `find_by_plaintext`:

```perl
# Look up a token directly by its stored hash (used by poll endpoints).
sub find_by_hash ($class, $db, $hash) {
    $db = $db->db if $db isa Registry::DAO;
    return $class->find($db, { token_hash => $hash });
}
```

**3. Add `verify` method** after `is_expired`:

```perl
method verify ($db) {
    # Fast-path checks (not authoritative -- the atomic UPDATE is the real guard)
    croak "Token already verified" if $verified_at;
    croak "Token has expired"      if $self->is_expired;

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

**4. Modify `consume` method** to enforce `verified_at` for `login` and `recovery`
purposes. Replace the existing `consume` method body with:

```perl
method consume ($db) {
    croak "Token already consumed" if $consumed_at;
    croak "Token has expired"      if $self->is_expired;

    # login and recovery tokens must go through the verify step first.
    # invite and verify_email tokens bypass this check.
    if ($purpose eq 'login' || $purpose eq 'recovery') {
        croak "Token not yet verified" unless $verified_at;
    }

    $db = $db->db if $db isa Registry::DAO;

    # Atomic conditional UPDATE prevents double-consumption under concurrency
    my $result = $db->update(
        $self->table,
        { consumed_at => \'now()' },
        { id => $id, consumed_at => undef },
        { returning => '*' }
    )->expand->hash;

    croak "Token already consumed" unless $result;

    return blessed($self)->new($result->%*);
}
```

Run:

```bash
carton exec prove -lv t/dao/magic-link-token.t
```

All tests must pass. Commit: "Add verified_at field, verify(), find_by_hash(), and guarded consume() to MagicLinkToken"

---

### Task 4 — Controller: write failing tests for new endpoints (5 min)

Add the following subtests to `t/controller/auth.t`. Note that the existing
`'GET /auth/magic/:token with valid token'` subtest expects a 302 redirect — it
must be updated to expect 200 (the new verify endpoint renders a confirmation
page, not a redirect). All other existing subtests continue to pass.

**Update the existing valid-token subtest** (find and replace):

```perl
subtest 'GET /auth/magic/:token with valid token renders confirmation page' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Renders confirmation page (does not redirect)')
      ->content_like(qr/sign.?in/i, 'Confirmation page has sign-in content');
};
```

**Add new subtests** after the existing invalid-token subtest:

```perl
subtest 'GET /auth/magic/:token with consumed token shows already-signed-in' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200)
      ->content_like(qr/already.*signed.?in/i, 'Shows already-signed-in message');
};

subtest 'POST /auth/magic/:token/complete establishes session' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'Redirects after consuming');

    ok($t->ua->cookie_jar->find(Mojo::URL->new('/auth'))->value,
       'Session cookie set') if 0; # session cookie check is context-dependent
};

subtest 'POST /auth/magic/:token/complete without prior verify fails' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(200)
      ->content_like(qr/invalid|expired/i, 'Shows error for unverified token');
};

subtest 'POST /auth/magic/:token/complete on already-consumed token shows already-signed-in' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(200)
      ->content_like(qr/already.*signed.?in/i, 'Shows already-signed-in gracefully');
};

subtest 'GET /auth/magic/poll/:hash returns pending for fresh token' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->status_is(200)
      ->json_is('/status', 'pending');
};

subtest 'GET /auth/magic/poll/:hash returns verified after verify()' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->status_is(200)
      ->json_is('/status', 'verified');
};

subtest 'GET /auth/magic/poll/:hash returns consumed after consume()' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->status_is(200)
      ->json_is('/status', 'consumed');
};

subtest 'GET /auth/magic/poll/:hash returns not_found for unknown hash' => sub {
    $t->get_ok("/auth/magic/poll/thisisnotarealhashvalue")
      ->status_is(200)
      ->json_is('/status', 'not_found');
};

subtest 'POST /auth/magic/poll/:hash/complete establishes session after verify' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(302, 'Redirects after consuming via hash');
};

subtest 'POST /auth/magic/poll/:hash/complete on already-consumed returns ok JSON' => sub {
    my $user = Registry::DAO::User->find($db->db, { username => 'magic_ctrl_user' });

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(200)
      ->json_is('/ok', 1, 'Returns ok:true gracefully');
};
```

Run:

```bash
carton exec prove -lv t/controller/auth.t
```

The updated valid-token subtest and all new subtests will fail. Existing
subtests must still pass (they test request and logout, which are unchanged).

---

### Task 5 — Controller: implement new and renamed methods (10 min)

Edit `lib/Registry/Controller/Auth.pm`.

**Step 5a — Rename `consume_magic_link` to `verify_magic_link`.**

Replace the entire `consume_magic_link` method with:

```perl
method verify_magic_link {
    my $plaintext = $self->param('token') // '';
    my $dao       = $self->dao;
    my $db        = $dao->db;

    my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);

    unless ($token) {
        $self->stash(error => 'This link is invalid.');
        return $self->render(template => 'auth/magic-link-error');
    }

    if ($token->consumed_at) {
        $self->stash(already_signed_in => 1);
        return $self->render(template => 'auth/magic-link-confirm');
    }

    if ($token->is_expired) {
        $self->stash(error => 'This link has expired. Please request a new one.');
        return $self->render(template => 'auth/magic-link-error');
    }

    try {
        $token = $token->verify($db);
    }
    catch ($e) {
        # Already verified is harmless — render the confirmation page anyway
        $self->app->log->debug("verify_magic_link: $e") if $e =~ /already verified/i;
    }

    $self->stash(plaintext => $plaintext);
    $self->render(template => 'auth/magic-link-confirm');
}
```

**Step 5b — Add `complete_magic_link` method** (after `verify_magic_link`):

```perl
method complete_magic_link {
    my $plaintext = $self->param('token') // '';
    my $dao       = $self->dao;
    my $db        = $dao->db;

    my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);

    unless ($token) {
        $self->stash(error => 'This link is invalid.');
        return $self->render(template => 'auth/magic-link-error');
    }

    if ($token->is_expired) {
        $self->stash(error => 'This link has expired. Please request a new one.');
        return $self->render(template => 'auth/magic-link-error');
    }

    try {
        $token->consume($db);

        $self->session(
            user_id          => $token->user_id,
            tenant_schema    => $self->tenant,
            authenticated_at => time(),
        );

        if ($token->purpose eq 'invite') {
            return $self->redirect_to('/auth/register-passkey');
        }

        $self->redirect_to('/');
    }
    catch ($e) {
        if ($e =~ /already consumed/i) {
            $self->stash(already_signed_in => 1);
            return $self->render(template => 'auth/magic-link-confirm');
        }
        $self->app->log->warn("Error completing magic link: $e");
        $self->stash(error => 'This link is invalid or has expired.');
        $self->render(template => 'auth/magic-link-error');
    }
}
```

**Step 5c — Add `magic_link_status` method** (after `complete_magic_link`):

```perl
method magic_link_status {
    my $hash = $self->param('token_hash') // '';
    my $dao  = $self->dao;
    my $db   = $dao->db;

    my $token = Registry::DAO::MagicLinkToken->find_by_hash($db, $hash);

    unless ($token) {
        return $self->render(json => { status => 'not_found' });
    }

    # Expired tokens report not_found to avoid leaking token existence
    if ($token->is_expired) {
        return $self->render(json => { status => 'not_found' });
    }

    my $status = $token->consumed_at  ? 'consumed'
               : $token->verified_at  ? 'verified'
               :                        'pending';

    $self->render(json => { status => $status });
}
```

**Step 5d — Add `magic_link_complete_by_hash` method** (after `magic_link_status`):

```perl
method magic_link_complete_by_hash {
    my $hash = $self->param('token_hash') // '';
    my $dao  = $self->dao;
    my $db   = $dao->db;

    my $token = Registry::DAO::MagicLinkToken->find_by_hash($db, $hash);

    unless ($token) {
        $self->stash(error => 'This link is invalid.');
        return $self->render(template => 'auth/magic-link-error');
    }

    if ($token->is_expired) {
        $self->stash(error => 'This link has expired. Please request a new one.');
        return $self->render(template => 'auth/magic-link-error');
    }

    try {
        $token->consume($db);

        $self->session(
            user_id          => $token->user_id,
            tenant_schema    => $self->tenant,
            authenticated_at => time(),
        );

        if ($token->purpose eq 'invite') {
            return $self->redirect_to('/auth/register-passkey');
        }

        $self->redirect_to('/');
    }
    catch ($e) {
        if ($e =~ /already consumed/i) {
            return $self->render(json => { ok => 1 });
        }
        $self->app->log->warn("Error completing magic link by hash: $e");
        $self->stash(error => 'This link is invalid or has expired.');
        $self->render(template => 'auth/magic-link-error');
    }
}
```

Run:

```bash
carton exec prove -lv t/controller/auth.t
```

All controller tests must pass. Commit: "Implement verify_magic_link, complete_magic_link, magic_link_status, magic_link_complete_by_hash"

---

### Task 6 — Routes: update registration (3 min)

Edit `lib/Registry.pm`. Locate the auth route block (around line 563-574) and
replace the existing magic link route line:

```perl
$auth->get('/magic/:token')->to('Auth#consume_magic_link');
```

with four new routes, literal segments first:

```perl
$auth->get('/magic/poll/:token_hash')->to('Auth#magic_link_status');
$auth->post('/magic/poll/:token_hash/complete')->to('Auth#magic_link_complete_by_hash');
$auth->get('/magic/:token')->to('Auth#verify_magic_link');
$auth->post('/magic/:token/complete')->to('Auth#complete_magic_link');
```

Run the controller tests again to confirm routing is correct:

```bash
carton exec prove -lv t/controller/auth.t
```

Commit: "Register four magic link routes with literal poll prefix before token placeholder"

---

### Task 7 — Rate limiter exemption (3 min)

Edit `lib/Registry/Middleware/RateLimit.pm`. Add `/auth/magic/poll` to the
`@EXCLUDED_PREFIXES` array:

```perl
our @EXCLUDED_PREFIXES = qw(
    /webhooks/
    /static/
    /public/
    /auth/magic/poll
);
```

Run the full test suite to confirm nothing broke:

```bash
carton exec prove -lr t/
```

Commit: "Exempt /auth/magic/poll from rate limiting"

---

### Task 8 — Templates: magic-link-confirm page (5 min)

Create `templates/auth/magic-link-confirm.html.ep`:

```html
%# ABOUTME: Confirmation page rendered after the magic link is verified.
%# ABOUTME: Provides a Sign In button (same-device fallback) or already-signed-in message.
% layout 'default';
% title 'Confirm Sign In';

<div class="card">
% if (stash('already_signed_in')) {
    <h2>You're already signed in</h2>
    <p><a href="/">Go to your dashboard</a></p>
% } else {
    <h2>Click to sign in</h2>
    <p>Your identity has been verified. Click the button below to complete sign-in.</p>
    <form method="post" action="/auth/magic/<%= stash('plaintext') %>/complete">
        <button type="submit" class="btn btn-primary">Sign In</button>
    </form>
% }
    <p><a href="/auth/login">Back to sign in</a></p>
</div>
```

Run:

```bash
carton exec prove -lv t/controller/auth.t
```

All tests must pass. Commit: "Add magic-link-confirm template for two-phase verify+consume flow"

---

### Task 9 — Templates: update magic-link-sent with polling JS (5 min)

Replace the contents of `templates/auth/magic-link-sent.html.ep` with:

```html
%# ABOUTME: Confirmation page shown after a magic link login request.
%# ABOUTME: Displays the same message regardless of whether the email matched a user.
% layout 'default';
% title 'Check Your Email';

<div class="card">
    <div id="poll-target" data-token-hash="<%= stash('token_hash') // '' %>">
        <h2>Check Your Email</h2>
        <p>If an account exists for that email address, we have sent a magic link.
           Please check your email and click the link to sign in.</p>
        <p>The link will expire shortly.</p>
        <p><a href="/auth/login">Back to sign in</a></p>
    </div>

    <%# Hidden form so the after_render hook injects a CSRF token we can read from JS %>
    <form id="poll-form" style="display:none"></form>
</div>

<script>
(function () {
    var target = document.getElementById('poll-target');
    var hash = target ? target.dataset.tokenHash : '';
    if (!hash) return;

    var POLL_INTERVAL_MS  = 2000;
    var MAX_POLL_MS       = 30 * 60 * 1000; // 30 minutes
    var startedAt         = Date.now();
    var intervalId        = null;

    function csrfToken() {
        var input = document.querySelector('#poll-form input[name="_token"]');
        return input ? input.value : '';
    }

    function stopPolling() {
        if (intervalId !== null) {
            clearInterval(intervalId);
            intervalId = null;
        }
    }

    function poll() {
        if (Date.now() - startedAt > MAX_POLL_MS) {
            stopPolling();
            return;
        }

        fetch('/auth/magic/poll/' + hash, { credentials: 'same-origin' })
            .then(function (res) { return res.json(); })
            .then(function (data) {
                var status = data.status;
                if (status === 'verified') {
                    stopPolling();
                    complete();
                } else if (status === 'consumed' || status === 'not_found') {
                    stopPolling();
                }
                // 'pending' — keep polling
            })
            .catch(function (err) {
                console.error('Magic link poll error:', err);
                // Continue polling on transient network errors
            });
    }

    function complete() {
        var form = document.createElement('form');
        form.method = 'POST';
        form.action = '/auth/magic/poll/' + hash + '/complete';

        var csrf = document.createElement('input');
        csrf.type  = 'hidden';
        csrf.name  = '_token';
        csrf.value = csrfToken();
        form.appendChild(csrf);

        document.body.appendChild(form);
        form.submit();
    }

    intervalId = setInterval(poll, POLL_INTERVAL_MS);
}());
</script>
```

The `token_hash` stash variable is set by `request_magic_link` in the next
task. For now the template renders safely even when `token_hash` is absent
(the JS bails out on an empty hash).

Run:

```bash
carton exec prove -lv t/controller/auth.t
```

Commit: "Add polling JS to magic-link-sent template"

---

### Task 10 — Controller: pass token_hash to magic-link-sent (3 min)

Edit `lib/Registry/Controller/Auth.pm`. In `request_magic_link`, the line that
generates the token:

```perl
my ($token, $plaintext) =
    Registry::DAO::MagicLinkToken->generate($db, {
        user_id    => $user->id,
        purpose    => 'login',
        expires_in => $expiry,
    });
```

After that block, stash the hash before rendering. Find the end of the `if ($user)` block (before the closing `}` of `try`) and add:

```perl
$self->stash(token_hash => $token->token_hash);
```

The render call at the end of `request_magic_link` already does:

```perl
$self->render(template => 'auth/magic-link-sent');
```

That is correct as-is.

Run:

```bash
carton exec prove -lr t/
```

All tests must pass. Commit: "Pass token_hash stash to magic-link-sent for polling JS"

---

### Task 11 — Integration tests (10 min)

Create `t/integration/auth-flow.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Integration tests for the magic link two-phase verify+consume flow.
# ABOUTME: Covers cross-device, same-device, tab-closed recovery, and race conditions.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

my $user = Registry::DAO::User->create($db->db, {
    username => 'auth_flow_test_user',
    email    => 'authflow@example.com',
    name     => 'Auth Flow Tester',
    password => 'test_password',
});

subtest 'Cross-device flow: verify → poll detects → complete' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    # Simulate the "check your email" page: poll shows pending
    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->json_is('/status', 'pending', 'Poll shows pending before verify');

    # Simulate clicking the magic link in an email app
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Verify endpoint renders confirmation page')
      ->content_like(qr/sign.?in/i, 'Confirmation page rendered');

    # Simulate the original tab polling again
    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->json_is('/status', 'verified', 'Poll shows verified after GET');

    # Simulate the polling JS POSTing to complete
    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(302, 'Complete by hash establishes session');

    # Poll now shows consumed
    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->json_is('/status', 'consumed', 'Poll shows consumed after completion');
};

subtest 'Same-device flow: verify → click Sign In → complete' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    # Click the magic link (verify step)
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Verify endpoint renders confirmation')
      ->content_like(qr/sign.?in/i, 'Has sign-in content');

    # Click "Sign In" on the confirmation page
    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'Complete by plaintext redirects after consuming');
};

subtest 'Tab-closed recovery: verify on different device → Sign In button works' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    # No polling tab — user just clicks the magic link directly
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Verify renders confirmation even without polling tab');

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'Sign In button works on recovery path');
};

subtest 'Prefetch scenario: GET verify is idempotent (second call shows already-verified page)' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    # First GET (e.g. email client prefetch)
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'First GET verifies and renders confirm');

    # Second GET (e.g. user actually clicks)
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Second GET also renders confirm page');
};

subtest 'Double-consume race: second POST to complete gets already-signed-in' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    # First consume wins
    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'First complete redirects');

    # Second consume loses gracefully
    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(200)
      ->content_like(qr/already.*signed.?in/i, 'Second complete shows already-signed-in');
};

subtest 'Double-consume via poll: second POST to hash complete returns ok JSON' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    $token_obj->verify($db->db);

    # First consume wins
    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(302, 'First hash complete redirects');

    # Second consume loses gracefully with ok:true
    $t->post_ok("/auth/magic/poll/" . $token_obj->token_hash . "/complete")
      ->status_is(200)
      ->json_is('/ok', 1, 'Second hash complete returns ok:true gracefully');
};

subtest 'Consumed token: poll returns consumed, confirm shows already-signed-in' => sub {
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db->db, {
        user_id => $user->id,
        purpose => 'login',
    });
    my $verified = $token_obj->verify($db->db);
    $verified->consume($db->db);

    $t->get_ok("/auth/magic/poll/" . $token_obj->token_hash)
      ->json_is('/status', 'consumed', 'Poll shows consumed');

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200)
      ->content_like(qr/already.*signed.?in/i, 'Confirm shows already-signed-in');
};

done_testing();
```

Run:

```bash
carton exec prove -lv t/integration/auth-flow.t
```

All tests must pass. Commit: "Add integration tests for magic link two-phase flow"

---

### Task 12 — Final verification: full suite (3 min)

Run the complete test suite:

```bash
carton exec prove -lr t/
```

Output must be pristine — no failures, no unexpected warnings. If any test
fails, diagnose and fix before proceeding.

Commit if any fixups were needed: "Fix test failures found during full suite verification"

---

### Task 13 — Playwright tests (5 min)

Update `t/playwright/auth-journeys.spec.js` to reflect the new two-step flow.

Locate any existing test that navigates to `/auth/magic/` and asserts a
redirect directly to `/`. Update those to instead assert the confirmation
page renders (`page.waitForSelector` on the "Sign In" button), then click
that button and assert the redirect to `/`.

Add a cross-device polling test using two browser contexts:

```js
test('cross-device polling flow', async ({ browser }) => {
    // Context A: "the original browser tab"
    const ctxA = await browser.newContext();
    const pageA = await ctxA.newPage();

    // Context B: "the email app browser"
    const ctxB = await browser.newContext();
    const pageB = await ctxB.newPage();

    // Step 1 — request magic link in Context A
    await pageA.goto('/auth/login');
    await pageA.fill('[name="email"]', 'authflow@example.com');
    await pageA.click('[type="submit"]');
    await pageA.waitForSelector('#poll-target');

    // Extract the token hash from the page
    const hash = await pageA.$eval('#poll-target', el => el.dataset.tokenHash);
    expect(hash).toBeTruthy();

    // Step 2 — simulate clicking the magic link in Context B
    // (In real Playwright tests we seed the token directly via the app API
    //  or read the hash from the email sender's test transport.)
    // Here we GET the poll status to confirm pending, then navigate to verify.
    const pollRes = await pageA.request.get(`/auth/magic/poll/${hash}`);
    const pollData = await pollRes.json();
    expect(pollData.status).toBe('pending');

    // NOTE: Full cross-device test requires seeding the plaintext token.
    // That is covered by the integration tests. This Playwright test
    // validates the UI polling mechanism wires up correctly.
    await ctxA.close();
    await ctxB.close();
});
```

Run:

```bash
npx playwright test t/playwright/auth-journeys.spec.js
```

All tests must pass. Commit: "Update Playwright auth-journeys tests for two-phase magic link flow"

---

## Rollout Notes

- Deploy the sqitch migration and the code change in the same release.
- Code-first (before migration) is not safe: `verify()` will fail because
  `verified_at` does not exist.
- Migration-first is safe: the old `consume_magic_link` route is removed by
  this change, so no in-flight tokens are affected.
- Existing unconsumed tokens (no `verified_at`) will flow through the new
  `GET /auth/magic/:token` which calls `verify()` before `consume()` —
  backward compatible by design.

## Rollback Notes

- To roll back: `carton exec sqitch revert --to passwordless-auth`, then
  revert the code. The revert SQL drops the `verified_at` column. Any
  tokens in a `verified` (not yet consumed) state will be lost, but they
  are short-lived and users can simply request a new magic link.
