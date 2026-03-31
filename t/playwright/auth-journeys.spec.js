// ABOUTME: End-to-end journey tests for the Registry passwordless auth system
// ABOUTME: Covers magic link login, email verification, logout, and login page structure

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

// ---------------------------------------------------------------------------
// Helper: create a test user and a magic link token via direct SQL, returning
// the plaintext token so the test can navigate to /auth/magic/<token>.
// ---------------------------------------------------------------------------
async function createUserWithMagicToken(testDB, opts = {}) {
  const email    = opts.email    || `playwright_${Date.now()}@example.com`;
  const username = opts.username || `pw_user_${Date.now()}`;
  const purpose  = opts.purpose  || 'login';

  // Use carton exec perl to run a small Perl one-liner against the test DB.
  // This keeps us in the real application stack (Registry::DAO) rather than
  // issuing raw SQL that could diverge from the ORM layer.
  const script = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    use Registry::DAO::User;
    use Registry::DAO::MagicLinkToken;

    my \\$dao  = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db   = \\$dao->db;

    my \\$user = Registry::DAO::User->find(\\$db, { email => '${email}' });
    unless (\\$user) {
        \\$user = Registry::DAO::User->create(\\$db, {
            username  => '${username}',
            email     => '${email}',
            name      => 'Playwright Test User',
            user_type => 'parent',
        });
    }

    my (\\$token, \\$plaintext) = Registry::DAO::MagicLinkToken->generate(\\$db, {
        user_id    => \\$user->id,
        purpose    => '${purpose}',
        expires_in => 24,
    });

    print \\$plaintext;
  `;

  const plaintext = execSync(
    `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: '/home/perigrin/dev/Registry', encoding: 'utf8' }
  ).trim();

  if (!plaintext) {
    throw new Error('Failed to create magic link token -- empty output from Perl helper');
  }

  return { email, username, plaintext };
}

// ===========================================================================
// 1. Login page structure
// ===========================================================================
test.describe('Login page structure', () => {
  test('has email input form posted to /auth/magic/request', async ({ registryPage }) => {
    await registryPage.goto('/auth/login');

    // Page title and heading
    await expect(registryPage).toHaveTitle(/Sign In/i);
    await expect(registryPage.locator('h2')).toContainText('Sign In');

    // Email input
    const emailInput = registryPage.locator('input[type="email"][name="email"]');
    await expect(emailInput).toBeVisible();
    await expect(emailInput).toHaveAttribute('required');

    // Submit button
    const submitBtn = registryPage.locator('button[type="submit"]');
    await expect(submitBtn).toBeVisible();

    // Form action
    const form = registryPage.locator('form');
    await expect(form).toHaveAttribute('action', '/auth/magic/request');
  });

  test('passkey section is present but hidden by default', async ({ registryPage }) => {
    await registryPage.goto('/auth/login');

    const passkeySection = registryPage.locator('#passkey-section');
    await expect(passkeySection).toBeAttached();

    // The section is hidden via inline style="display:none;"
    const display = await passkeySection.evaluate(el => el.style.display);
    expect(display).toBe('none');
  });
});

// ===========================================================================
// 2. Magic link request -- confirmation page
// ===========================================================================
test.describe('Magic link request flow', () => {
  test('submitting email shows check-your-email confirmation', async ({ registryPage, testDB }) => {
    // Create a real user so the controller sends an email (captured by the
    // Email::Sender::Transport::Test transport -- nothing actually goes out).
    const ts    = Date.now();
    const email = `magic_request_${ts}@example.com`;
    execSync(
      `carton exec perl -e "` +
      `use lib qw(lib t/lib); use Registry::DAO; use Registry::DAO::User; ` +
      `my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}'); ` +
      `my \\$db = \\$dao->db; ` +
      `Registry::DAO::User->create(\\$db, { username => 'mlu_${ts}', email => '${email}', name => 'Magic User', user_type => 'parent' });"`,
      { cwd: '/home/perigrin/dev/Registry', encoding: 'utf8' }
    );

    // Fill the real browser form -- this exercises the full round-trip including
    // CSRF validation, since the form already contains the injected hidden field.
    await registryPage.goto('/auth/login');
    await registryPage.locator('input[name="email"]').fill(email);
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');

    // Should land on the magic-link-sent page
    await expect(registryPage.locator('h2')).toContainText('Check Your Email');
    await expect(registryPage.locator('body')).toContainText('magic link');
  });

  test('submitting unknown email still shows check-your-email (anti-enumeration)', async ({ registryPage }) => {
    await registryPage.goto('/auth/login');
    await registryPage.locator('input[name="email"]').fill('nobody_at_all@notreal.invalid');
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');

    // Must show the same confirmation page to prevent user enumeration
    await expect(registryPage.locator('h2')).toContainText('Check Your Email');
  });
});

// ===========================================================================
// 3. Magic link consumption -- successful login
// ===========================================================================
test.describe('Magic link consumption', () => {
  test('valid token authenticates user and redirects to /', async ({ registryPage, testDB }) => {
    const { plaintext } = await createUserWithMagicToken(testDB, {
      email:    `valid_magic_${Date.now()}@example.com`,
      username: `valid_magic_user_${Date.now()}`,
    });

    const response = await registryPage.goto(`/auth/magic/${plaintext}`);

    // The controller calls redirect_to('/') after consuming the token.
    // Playwright follows the redirect, so we end up on the root page.
    expect(response.url()).not.toContain('/auth/magic/');
    expect(response.status()).toBeLessThan(400);

    // Session cookie should be set -- navigating to a public page works
    await registryPage.goto('/');
    await expect(registryPage.locator('body')).toBeAttached();
  });

  test('valid token grants access to a protected route', async ({ registryPage, testDB }) => {
    // Create an admin user so /admin/dashboard is accessible after auth
    const email    = `admin_magic_${Date.now()}@example.com`;
    const username = `admin_magic_${Date.now()}`;

    const script = `
      use lib qw(lib t/lib);
      use Registry::DAO;
      use Registry::DAO::User;
      use Registry::DAO::MagicLinkToken;

      my \\$dao  = Registry::DAO->new(url => '${testDB.dbUrl}');
      my \\$db   = \\$dao->db;

      my \\$user = Registry::DAO::User->create(\\$db, {
          username  => '${username}',
          email     => '${email}',
          name      => 'Admin Magic User',
          user_type => 'admin',
      });

      my (\\$token, \\$plaintext) = Registry::DAO::MagicLinkToken->generate(\\$db, {
          user_id    => \\$user->id,
          purpose    => 'login',
          expires_in => 24,
      });

      print \\$plaintext;
    `;

    const plaintext = execSync(
      `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
      { cwd: '/home/perigrin/dev/Registry', encoding: 'utf8' }
    ).trim();

    // Consume the magic link to establish a session
    await registryPage.goto(`/auth/magic/${plaintext}`);
    await registryPage.waitForLoadState('networkidle');

    // Now attempt a protected admin route -- should NOT redirect to login
    const adminResponse = await registryPage.goto('/admin/dashboard');
    expect(adminResponse.url()).not.toContain('/auth/login');
    expect(adminResponse.status()).toBeLessThan(400);
  });
});

// ===========================================================================
// 4. Invalid and expired magic links
// ===========================================================================
test.describe('Invalid magic links', () => {
  test('completely invalid token shows error page', async ({ registryPage }) => {
    await registryPage.goto('/auth/magic/this_is_not_a_real_token_at_all');

    await expect(registryPage.locator('h2')).toContainText('Invalid Link');
    await expect(registryPage.locator('body')).toContainText('invalid');
    // Page should offer a link back to the login page
    await expect(registryPage.locator('a[href="/auth/login"]')).toBeVisible();
  });

  test('already-consumed token shows already-used error', async ({ registryPage, testDB }) => {
    const { plaintext } = await createUserWithMagicToken(testDB, {
      email:    `consumed_magic_${Date.now()}@example.com`,
      username: `consumed_magic_${Date.now()}`,
    });

    // Consume it once (legitimate login)
    await registryPage.goto(`/auth/magic/${plaintext}`);
    await registryPage.waitForLoadState('networkidle');

    // Attempt to reuse the same token
    await registryPage.goto(`/auth/magic/${plaintext}`);
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('h2')).toContainText('Invalid Link');
    await expect(registryPage.locator('body')).toContainText('already been used');
  });
});

// ===========================================================================
// 5. Logout
// ===========================================================================
test.describe('Logout flow', () => {
  test('logout clears session and redirects', async ({ registryPage, testDB }) => {
    // First authenticate via magic link
    const { plaintext } = await createUserWithMagicToken(testDB, {
      email:    `logout_user_${Date.now()}@example.com`,
      username: `logout_user_${Date.now()}`,
    });

    await registryPage.goto(`/auth/magic/${plaintext}`);
    await registryPage.waitForLoadState('networkidle');

    // Confirm we're authenticated -- the root page loads without redirect to login
    const beforeLogout = await registryPage.goto('/');
    expect(beforeLogout.url()).not.toContain('/auth/login');

    // Perform logout.  The logout endpoint is POST /auth/logout.
    // We need the CSRF token from any page that sets a session.
    const csrf = await registryPage.evaluate(() => {
      // Mojolicious sets the CSRF token as a cookie named 'csrf_token'
      const match = document.cookie.match(/csrf_token=([^;]+)/);
      return match ? decodeURIComponent(match[1]) : '';
    });

    // POST to /auth/logout via fetch, maintaining the session cookie
    await registryPage.evaluate(
      async ({ serverUrl, csrf }) => {
        const fd = new FormData();
        fd.append('csrf_token', csrf);
        await fetch(serverUrl + '/auth/logout', {
          method: 'POST',
          body: fd,
          credentials: 'include',
          redirect: 'manual',
        });
      },
      { serverUrl: registryPage.serverUrl, csrf }
    );

    // Navigate to a protected route -- should now redirect to login
    const afterLogout = await registryPage.goto('/admin/dashboard');
    // After logout, require_auth redirects browsers to /auth/login
    expect(afterLogout.url()).toContain('/auth/login');
  });
});

// ===========================================================================
// 6. Email verification
// ===========================================================================
test.describe('Email verification flow', () => {
  test('valid verify_email token shows success message', async ({ registryPage, testDB }) => {
    const { plaintext } = await createUserWithMagicToken(testDB, {
      email:    `verify_user_${Date.now()}@example.com`,
      username: `verify_user_${Date.now()}`,
      purpose:  'verify_email',
    });

    await registryPage.goto(`/auth/verify-email/${plaintext}`);

    await expect(registryPage.locator('h2')).toContainText('Email Verified');
    await expect(registryPage.locator('body')).toContainText('confirmed');
    // Should offer a sign-in link
    await expect(registryPage.locator('a[href="/auth/login"]')).toBeVisible();
  });

  test('invalid verification token shows failure message', async ({ registryPage }) => {
    await registryPage.goto('/auth/verify-email/not_a_real_verify_token_123');

    await expect(registryPage.locator('h2')).toContainText('Verification Failed');
    await expect(registryPage.locator('body')).toContainText('invalid');
  });

  test('already-consumed verification token shows expired/used message', async ({ registryPage, testDB }) => {
    const { plaintext } = await createUserWithMagicToken(testDB, {
      email:    `verify_twice_${Date.now()}@example.com`,
      username: `verify_twice_${Date.now()}`,
      purpose:  'verify_email',
    });

    // Consume once
    await registryPage.goto(`/auth/verify-email/${plaintext}`);
    await registryPage.waitForLoadState('networkidle');

    // Second attempt
    await registryPage.goto(`/auth/verify-email/${plaintext}`);
    await expect(registryPage.locator('h2')).toContainText('Verification Failed');
  });
});
