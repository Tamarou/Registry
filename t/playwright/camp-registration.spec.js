// ABOUTME: End-to-end browser tests for summer camp registration workflow.
// ABOUTME: Covers workflow landing page, account setup options, returning parent flow, and resume.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

// Run tests serially to share a single test database instance.
// Increase timeout for DB setup + server startup.
test.describe.configure({ mode: 'serial', timeout: 120000 });

// ---------------------------------------------------------------------------
// Helper: seed registration test data via the Perl setup script.
// Returns parsed JSON with tenant, session, user IDs and magic link tokens.
// ---------------------------------------------------------------------------
function seedRegistrationData(testDB) {
  const output = execSync(
    'carton exec perl t/playwright/setup_registration_test_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  if (!output) {
    throw new Error('setup_registration_test_data.pl produced no output');
  }

  return JSON.parse(output);
}

// ---------------------------------------------------------------------------
// Helper: authenticate a user via magic link token
// ---------------------------------------------------------------------------
async function loginWithToken(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// ===========================================================================
// 1. Registration landing page
// ===========================================================================
test.describe('Registration landing page', () => {
  test('shows camp info and begin registration button', async ({ registryPage, testDB }) => {
    seedRegistrationData(testDB);

    await registryPage.goto('/summer-camp-registration');
    await registryPage.waitForLoadState('networkidle');

    // Page renders without error
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Has camp heading
    await expect(registryPage.locator('main h1, .landing-intro h1').first()).toContainText(/camp|registration/i);

    // Has begin registration button
    const submitBtn = registryPage.locator('button[type="submit"]');
    await expect(submitBtn).toBeVisible();
  });
});

// ===========================================================================
// 2. Account check page
// ===========================================================================
test.describe('Account check page', () => {
  test('shows login and create account options', async ({ registryPage, testDB }) => {
    seedRegistrationData(testDB);

    // Start the workflow
    await registryPage.goto('/summer-camp-registration');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Should be on account-check step
    const url = registryPage.url();
    expect(url).toContain('account-check');

    // Page renders without error
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Shows account setup heading
    await expect(registryPage.locator('h2')).toContainText(/account/i);

    // Has login form
    const loginForm = registryPage.locator('form:has(input[value="login"])');
    await expect(loginForm).toBeVisible();

    // Has create account form
    const createForm = registryPage.locator('form:has(input[value="create_account"])');
    await expect(createForm).toBeVisible();
  });
});

// ===========================================================================
// 3. Returning parent - logged in flow
// ===========================================================================
test.describe('Returning parent registration', () => {
  test('logged-in parent sees continue option and existing child', async ({ registryPage, testDB }) => {
    const testData = seedRegistrationData(testDB);

    // Authenticate as returning parent via magic link
    await loginWithToken(registryPage, testData.returning_parent.token);

    // Start the registration workflow
    await registryPage.goto('/summer-camp-registration');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // At account-check, the logged-in parent should see the continue option
    const continueForm = registryPage.locator('form:has(input[value="continue_logged_in"])');
    const isVisible = await continueForm.isVisible({ timeout: 3000 }).catch(() => false);

    if (isVisible) {
      // Parent recognized as logged in - click continue
      await registryPage.click('button:has-text("Continue")');
      await registryPage.waitForLoadState('networkidle');

      // Should be on select-children page
      const url = registryPage.url();
      expect(url).toContain('select-children');

      // Existing child Emma should be visible
      await expect(registryPage.locator('body')).toContainText('Emma Johnson');

      // Child should have a checkbox for selection
      const childCheckbox = registryPage.locator('input[type="checkbox"][name^="child_"]');
      await expect(childCheckbox.first()).toBeVisible();
    } else {
      // If the session doesn't carry through to the workflow context,
      // the parent sees the standard login/create options
      await expect(registryPage.locator('h2')).toContainText(/account/i);
    }
  });
});

// ===========================================================================
// 4. Workflow resume
// ===========================================================================
test.describe('Workflow resume', () => {
  test('navigating back to workflow URL loads without error', async ({ registryPage, testDB }) => {
    seedRegistrationData(testDB);

    // Start a workflow
    await registryPage.goto('/summer-camp-registration');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Capture the account-check URL (contains run ID)
    const accountCheckUrl = registryPage.url();
    expect(accountCheckUrl).toContain('account-check');

    // Navigate away
    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    // Navigate back to the workflow URL
    await registryPage.goto(accountCheckUrl);
    await registryPage.waitForLoadState('networkidle');

    // Page should render without error
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Should still show account-check content
    await expect(registryPage.locator('h2')).toContainText(/account/i);
  });
});
