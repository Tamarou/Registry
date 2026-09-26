// ABOUTME: End-to-end browser tests for the admin dashboard.
// ABOUTME: Covers program overview, today's events, waitlist management, and enrollment trends.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

// Run tests serially to share state.
test.describe.configure({ mode: 'serial', timeout: 120000 });

// ---------------------------------------------------------------------------
// Helper: seed test data and create an admin user with a magic link token
// ---------------------------------------------------------------------------
function seedAdminData(testDB) {
  const output = execSync(
    'carton exec perl t/playwright/setup_admin_test_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  if (!output) {
    throw new Error('setup_admin_test_data.pl produced no output');
  }

  return JSON.parse(output);
}

// ---------------------------------------------------------------------------
// Helper: authenticate via magic link
// ---------------------------------------------------------------------------
async function loginWithToken(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// ===========================================================================
// Admin Dashboard Tests
// ===========================================================================
test.describe('Admin dashboard', () => {
  test('dashboard renders with program overview section', async ({ registryPage, testDB }) => {
    const data = seedAdminData(testDB);
    await loginWithToken(registryPage, data.token);

    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Dashboard should show some content
    const bodyText = await registryPage.locator('body').textContent();
    expect(bodyText).toMatch(/dashboard|overview|program|enrollment|admin/i);
  });

  test('HTMX program overview endpoint loads', async ({ registryPage, testDB }) => {
    const data = seedAdminData(testDB);
    await loginWithToken(registryPage, data.token);

    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');

    // Wait for HTMX endpoints to load (they fire on page load)
    await registryPage.waitForTimeout(2000);

    // The page should have loaded HTMX content sections
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
  });

  test('HTMX endpoint URLs are present in dashboard page', async ({ registryPage, testDB }) => {
    const data = seedAdminData(testDB);
    await loginWithToken(registryPage, data.token);

    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // `ok: true;` is a JavaScript label, not an assertion -- it is what stood
    // here, and it computed hasHTMXEndpoints without ever looking at it. The
    // dashboard loads its panels over HTMX, so the attributes that fetch them
    // are the thing to require: without them the page renders empty shells.
    const htmxTargets = registryPage.locator('[hx-get], [hx-post]');
    await expect(htmxTargets.first(), 'the dashboard wires up its HTMX panels')
      .toBeAttached({ timeout: 10000 });

    // Pointed at the section endpoints the page actually uses -- `?section=`
    // through the workflow, not the `/admin/dashboard/<section>` fragment routes
    // the old Jordan tests asserted and no screen ever called.
    const targets = await htmxTargets.evaluateAll((els) =>
      els.map((el) => el.getAttribute('hx-get') || el.getAttribute('hx-post'))
    );
    expect(targets.some((t) => t && t.includes('section=')),
      'at least one panel fetches a section').toBeTruthy();
  });

  test('unauthenticated access redirects to login', async ({ registryPage, testDB }) => {
    seedAdminData(testDB);

    // Access without login
    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');

    // The old test also accepted body text matching /sign in|login|unauthorized/,
    // which the dashboard's own navigation satisfies -- so it passed whether or
    // not the guard held. What matters is that the dashboard's content is NOT
    // served, so that is the assertion.
    await expect(registryPage.locator('nav.dashboard-nav')).toHaveCount(0);
    await expect(registryPage).not.toHaveTitle(/Admin Dashboard/);
  });
});
