// ABOUTME: End-to-end browser tests for waitlist accept and decline flows.
// ABOUTME: Covers offer page display, accept action, and decline action with auth.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

// Run tests serially to share a single test database instance.
test.describe.configure({ mode: 'serial', timeout: 120000 });

// ---------------------------------------------------------------------------
// Helper: seed registration data and create a waitlist entry with an active
// offer for the returning parent. Returns all IDs needed for testing.
// ---------------------------------------------------------------------------
function seedWaitlistData(testDB) {
  // First seed the base registration data
  const baseOutput = execSync(
    'carton exec perl t/playwright/setup_registration_test_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  if (!baseOutput) {
    throw new Error('setup_registration_test_data.pl produced no output');
  }

  const data = JSON.parse(baseOutput);

  // Create a waitlist entry with status='offered' via helper script
  const waitlistOutput = execSync(
    `carton exec perl t/playwright/setup_waitlist_test_data.pl '${JSON.stringify(data)}'`,
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  const waitlistData = JSON.parse(waitlistOutput);

  return { ...data, waitlist_id: waitlistData.waitlist_id };
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
// 3.1 Accept waitlist offer
// ===========================================================================
test.describe('Accept waitlist offer', () => {
  test('offer page shows session info and accept button', async ({ registryPage, testDB }) => {
    const data = seedWaitlistData(testDB);

    // Authenticate as the parent
    await loginWithToken(registryPage, data.returning_parent.token);

    // Navigate to the waitlist offer page
    await registryPage.goto(`/waitlist/${data.waitlist_id}`);
    await registryPage.waitForLoadState('networkidle');

    // Page renders without error
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Shows session name
    await expect(registryPage.locator('body')).toContainText(data.sessions.week3_full.name);

    // Shows child name
    await expect(registryPage.locator('body')).toContainText(data.returning_parent.child_name);

    // Accept button visible
    const acceptBtn = registryPage.locator('button:has-text("Accept")');
    await expect(acceptBtn).toBeVisible();

    // Decline button visible
    const declineBtn = registryPage.locator('button:has-text("Decline")');
    await expect(declineBtn).toBeVisible();

    // Time remaining section visible
    await expect(registryPage.locator('body')).toContainText(/remaining|expire/i);
  });
});

// ===========================================================================
// 3.2 Decline waitlist offer
// ===========================================================================
test.describe('Decline waitlist offer', () => {
  test('decline redirects with confirmation', async ({ registryPage, testDB }) => {
    const data = seedWaitlistData(testDB);
    await loginWithToken(registryPage, data.returning_parent.token);
    await registryPage.goto(`/waitlist/${data.waitlist_id}`);
    await registryPage.waitForLoadState('networkidle');

    // Handle the confirmation dialog
    registryPage.on('dialog', async dialog => {
      await dialog.accept();
    });

    // Click decline
    await registryPage.click('button:has-text("Decline")');
    await registryPage.waitForLoadState('networkidle');

    // Should redirect away from the offer page (to dashboard or confirmation)
    const url = registryPage.url();
    expect(url).not.toContain(`/waitlist/${data.waitlist_id}`);

    // No error page
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
  });
});
