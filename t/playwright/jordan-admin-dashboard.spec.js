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

// Mint a fresh single-use magic link token for the given user.
// Magic link tokens are single-use; call this right before each loginWithToken.
// Perl sigils must be escaped with \\$ so the shell does not consume them.
function freshToken(testDB, userId) {
  const script = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    use Registry::DAO::MagicLinkToken;
    my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db  = \\$dao->db;
    my (undef, \\$pt) = Registry::DAO::MagicLinkToken->generate(\\$db, {
        user_id    => '${userId}',
        purpose    => 'login',
        expires_in => 24,
    });
    print \\$pt;
  `;

  const plaintext = execSync(
    `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: process.cwd(), encoding: 'utf8' }
  ).trim();

  if (!plaintext) {
    throw new Error('freshToken: empty output from Perl helper');
  }
  return plaintext;
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

  test('Jordan logs in via magic link', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.admin_id));

    // Every URL contains a slash, so the assertion this replaces held on the
    // login page and on a 500 as readily as on a signed-in one. Being signed in
    // means the dashboard renders as his, so that is what gets asserted.
    await registryPage.goto('/admin/dashboard');
    await expect(registryPage).not.toHaveURL(/\/auth\//);
    await expect(registryPage).toHaveTitle(/Admin Dashboard/);
  });

  test('Jordan navigates to admin dashboard', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.admin_id));
    await registryPage.goto('/admin/dashboard');

    // Dashboard renders with navigation
    await expect(registryPage.locator('nav.dashboard-nav')).toBeVisible();
    await expect(registryPage).toHaveTitle(/Admin Dashboard/);
  });

  test('Jordan sees navigation with admin tools', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.admin_id));
    await registryPage.goto('/admin/dashboard');

    // Check nav links exist
    const nav = registryPage.locator('nav.dashboard-nav');
    await expect(nav.locator('a[href="/program-creation"]')).toBeVisible();
    await expect(nav.locator('a[href="/admin/templates"]')).toBeVisible();
    await expect(nav.locator('a[href="/admin/domains"]')).toBeVisible();
    await expect(nav.locator('a[href="/teacher/"]')).toBeVisible();
  });

  test('Jordan can navigate to program creation', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.admin_id));
    await registryPage.goto('/admin/dashboard');

    // Click program creation link
    await registryPage.locator('nav.dashboard-nav a[href="/program-creation"]').click();
    await registryPage.waitForLoadState('networkidle');

    // Should be on the program creation page
    await expect(registryPage).toHaveURL(/program-creation/);
  });

  test('Jordan can navigate to template editor', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.admin_id));
    await registryPage.goto('/admin/dashboard');

    await registryPage.locator('nav.dashboard-nav a[href="/admin/templates"]').click();
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage).toHaveURL(/admin\/templates/);
  });

  test('Jordan can export enrollment data', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.admin_id));
    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');

    // The export lives behind a dropdown button, and the screen is what has to
    // offer it. Requesting the URL directly -- which is what this test used to
    // do -- passes just as well when the button, the dropdown or the link has
    // gone, and Jordan then has no way to reach a working endpoint.
    await registryPage.getByRole('button', { name: /export data/i }).click();

    const link = registryPage.locator('#export-dropdown a', { hasText: 'Enrollments (CSV)' });
    await expect(link, 'the dropdown offers a CSV of enrolments').toBeVisible();

    // Followed rather than guessed: the href the screen carries is the one that
    // must work, so a link pointing at the wrong type or format fails here.
    const href = await link.getAttribute('href');
    const response = await registryPage.request.get(href);
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toMatch(/csv/);

    // A 200 of nothing is not an export. The header row names the columns, so
    // its absence means the endpoint answered without the data behind it.
    const csv = await response.text();
    expect(csv.split('\n')[0], 'the CSV has a header row').toMatch(/,/);
  });
});
