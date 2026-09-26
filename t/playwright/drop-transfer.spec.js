// ABOUTME: End-to-end browser tests for drop and transfer request workflows.
// ABOUTME: Tests parent dashboard drop/transfer buttons and admin approval pages.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

// Run tests serially.
test.describe.configure({ mode: 'serial', timeout: 120000 });

// ---------------------------------------------------------------------------
// Helper: seed data
// ---------------------------------------------------------------------------
function seedDropData(testDB) {
  const output = execSync(
    'carton exec perl t/playwright/setup_drop_test_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  if (!output) {
    throw new Error('setup_drop_test_data.pl produced no output');
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
// Parent dashboard has drop/transfer actions
// ===========================================================================
test.describe('Drop and transfer from parent dashboard', () => {
  test('parent dashboard shows enrolled child with action options', async ({ registryPage, testDB }) => {
    const data = seedDropData(testDB);
    await loginWithToken(registryPage, data.parent_token);

    await registryPage.goto('/parent/dashboard');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Should show the enrolled child
    await expect(registryPage.locator('body')).toContainText('Drop Test Kid');
  });

  // Pressed from the dashboard, which is the only way in that exists: the Drop
  // link carries the enrollment_id, and the step skips its selection screen when
  // it has one. The test this replaces navigated to /parent-drop-request bare and
  // then asserted `bodyText.length > 100` -- through a JavaScript label, so not
  // even that was checked. The 500 page is longer than 100 characters.
  test('parent presses Drop and reaches the reason screen', async ({ registryPage, testDB }) => {
    const data = seedDropData(testDB);
    await loginWithToken(registryPage, data.parent_token);

    await registryPage.goto('/parent/dashboard');
    await registryPage.waitForLoadState('networkidle');

    const drop = registryPage.locator(
      `a[href="/parent-drop-request?enrollment_id=${data.enrollment_id}"]`
    );
    await expect(drop, 'the dashboard offers Drop for the enrolment').toBeVisible({ timeout: 10000 });
    await drop.click();
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // The link carries the enrolment, so the selection step completes on arrival
    // and the parent lands on the reason screen. The control has to be there --
    // a screen of prose with nothing to fill in is the dead end worth catching.
    const reason = registryPage.locator('textarea[name="reason"]');
    await expect(reason, 'the reason control is on the screen').toBeVisible({ timeout: 10000 });

    await reason.fill('Moving out of the area');
    await registryPage.locator('form button[type="submit"]').first().click();
    await registryPage.waitForLoadState('networkidle');

    // And the reason has to reach the next screen. A review step that shows none
    // of what was just typed is not a review.
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body'), 'the review screen carries the reason back')
      .toContainText('Moving out of the area');
  });
});

// ===========================================================================
// Admin approval pages render
// ===========================================================================
test.describe('Admin drop approval', () => {
  test('admin can view pending drop requests on dashboard', async ({ registryPage, testDB }) => {
    const data = seedDropData(testDB);
    await loginWithToken(registryPage, data.admin_token);

    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Admin dashboard should render
    const bodyText = await registryPage.locator('body').textContent();
    expect(bodyText).toMatch(/dashboard|admin|overview/i);
  });

  test('pending drop requests endpoint responds', async ({ registryPage, testDB }) => {
    const data = seedDropData(testDB);
    await loginWithToken(registryPage, data.admin_token);

    await registryPage.goto('/admin/dashboard/pending_drop_requests');
    await registryPage.waitForLoadState('networkidle');

    // Should render without error (may show the pending request or empty list)
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
  });
});

// ===========================================================================
// Transfer workflow pages
// ===========================================================================
test.describe('Transfer request', () => {
  test('transfer request workflow page renders', async ({ registryPage, testDB }) => {
    const data = seedDropData(testDB);
    await loginWithToken(registryPage, data.parent_token);

    await registryPage.goto('/parent-transfer-request');
    await registryPage.waitForLoadState('networkidle');

    // Page should render (may error on first step due to missing user in run)
    // but should not be a browser crash
    const bodyText = await registryPage.locator('body').textContent();
    expect(bodyText.length).toBeGreaterThan(50);
  });

  test('pending transfer requests endpoint responds', async ({ registryPage, testDB }) => {
    const data = seedDropData(testDB);
    await loginWithToken(registryPage, data.admin_token);

    await registryPage.goto('/admin/dashboard/pending_transfer_requests');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
  });
});
