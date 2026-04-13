// ABOUTME: End-to-end browser test for Jordan's admin dashboard journey.
// ABOUTME: Tests navigation, program overview, data export, and tool access.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

test.describe.configure({ mode: 'serial', timeout: 120000 });

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

async function loginWithToken(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// ===========================================================================
// Jordan's Admin Dashboard Journey
// ===========================================================================
test.describe('Jordan admin dashboard journey', () => {
  let testData;

  test.beforeAll(async ({ testDB }) => {
    testData = seedAdminData(testDB);
  });

  test('Jordan logs in via magic link', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.token);
    // Should redirect to home or dashboard after login
    await expect(registryPage).toHaveURL(/\//);
  });

  test('Jordan navigates to admin dashboard', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.token);
    await registryPage.goto('/admin/dashboard');

    // Dashboard renders with navigation
    await expect(registryPage.locator('nav.dashboard-nav')).toBeVisible();
    await expect(registryPage.locator('text=Admin Dashboard')).toBeVisible();
  });

  test('Jordan sees navigation with admin tools', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.token);
    await registryPage.goto('/admin/dashboard');

    // Check nav links exist
    const nav = registryPage.locator('nav.dashboard-nav');
    await expect(nav.locator('a[href="/program-creation"]')).toBeVisible();
    await expect(nav.locator('a[href="/admin/templates"]')).toBeVisible();
    await expect(nav.locator('a[href="/admin/domains"]')).toBeVisible();
    await expect(nav.locator('a[href="/teacher/"]')).toBeVisible();
  });

  test('Jordan can navigate to program creation', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.token);
    await registryPage.goto('/admin/dashboard');

    // Click program creation link
    await registryPage.locator('nav.dashboard-nav a[href="/program-creation"]').click();
    await registryPage.waitForLoadState('networkidle');

    // Should be on the program creation page
    await expect(registryPage).toHaveURL(/program-creation/);
  });

  test('Jordan can navigate to template editor', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.token);
    await registryPage.goto('/admin/dashboard');

    await registryPage.locator('nav.dashboard-nav a[href="/admin/templates"]').click();
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage).toHaveURL(/admin\/templates/);
  });

  test('Jordan can export enrollment data', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.token);

    // Request CSV export directly
    const response = await registryPage.request.get('/admin/dashboard/export?type=enrollments&format=csv');
    expect(response.status()).toBe(200);
  });
});
