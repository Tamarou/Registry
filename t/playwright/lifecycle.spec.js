// ABOUTME: Serial lifecycle E2E — Morgan signs up, builds a free program; Nancy
// ABOUTME: enrolls her child; Amara takes attendance — all in Morgan's tenant schema.
const { test, expect } = require('./fixtures/base');
const { execFileSync } = require('child_process');

function helper(testDB, args) {
  return execFileSync(
    'carton',
    ['exec', 'perl', 't/playwright/lifecycle_helpers.pl', ...args],
    { cwd: process.cwd(), env: { ...process.env, DB_URL: testDB.dbUrl }, encoding: 'utf8' }
  ).trim();
}
function loginToken(testDB, schema, userId) { return helper(testDB, ['login-token', schema, userId]); }
function queryJson(testDB, schema, sql, ...bind) { return JSON.parse(helper(testDB, ['query-json', schema, sql, ...bind.map(String)])); }

async function loginWithToken(page, token, baseUrl = '') {
  await page.goto(`${baseUrl}/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

test.describe.configure({ mode: 'serial', timeout: 180000 });

const RUN = String(Date.now());
const state = {
  orgName: `Lifecycle Arts ${RUN}`,
  morganUsername: `morgan_${RUN}`, morganEmail: `morgan_${RUN}@test.com`,
  amaraUsername: `amara_${RUN}`,   amaraEmail: `amara_${RUN}@test.com`,
  nancyUsername: `nancy_${RUN}`,   nancyEmail: `nancy_${RUN}@test.com`,
  childName: `Kid ${RUN}`,
};

test.describe('Lifecycle: Morgan -> Nancy -> Amara', () => {

  test('Leg 0: Morgan signs up and her tenant is provisioned', async ({ registryPage, testDB }) => {
    // Clear session so we always get a fresh workflow run
    await registryPage.context().clearCookies();

    // ----------------------------------------------------------------
    // Landing step
    // ----------------------------------------------------------------
    await registryPage.goto('/tenant-signup');
    await registryPage.waitForLoadState('networkidle');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Profile step
    // ----------------------------------------------------------------
    await expect(registryPage.locator('input[name="name"]')).toBeVisible({ timeout: 5000 });
    await registryPage.fill('input[name="name"]', state.orgName);
    await registryPage.fill('input[name="billing_email"]', state.morganEmail);
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Users step — fill Morgan's admin account and invite Amara as staff
    // ----------------------------------------------------------------
    await expect(registryPage.locator('input[name="admin_name"]')).toBeVisible({ timeout: 5000 });
    await registryPage.fill('input[name="admin_name"]', 'Morgan Admin');
    await registryPage.fill('input[name="admin_email"]', state.morganEmail);
    await registryPage.fill('input[name="admin_username"]', state.morganUsername);

    // Click "Add Team Member" to inject the dynamic card for Amara
    await registryPage.click('#add-member-btn');
    await registryPage.waitForTimeout(300); // let JS render the card

    // Fill the dynamically-inserted first team member card (index 0)
    await registryPage.fill('input[name="team_members[0][name]"]', 'Amara Teacher');
    await registryPage.fill('input[name="team_members[0][email]"]', state.amaraEmail);
    // Role select defaults to "staff"; ensure it is set explicitly
    await registryPage.selectOption('select[name="team_members[0][user_type]"]', 'staff');

    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Pricing step (optional — skipped when no plans are configured)
    // ----------------------------------------------------------------
    const pricingVisible = await registryPage.locator('h1, h2').filter({ hasText: /plan|pricing/i })
      .isVisible({ timeout: 2000 }).catch(() => false);
    if (pricingVisible) {
      const planInput = registryPage.locator('input[name="selected_plan_id"]').first();
      if (await planInput.isVisible({ timeout: 1000 }).catch(() => false)) {
        await planInput.check();
      }
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // ----------------------------------------------------------------
    // Review step — check terms and click the JS-gated proceed button
    // ----------------------------------------------------------------
    const termsInput = registryPage.locator('input[name="terms_accepted"]');
    if (await termsInput.isVisible({ timeout: 3000 }).catch(() => false)) {
      await termsInput.check();
      const proceedBtn = registryPage.locator('#proceed-to-payment');
      await expect(proceedBtn).toBeEnabled({ timeout: 5000 });
      await proceedBtn.click();
      await registryPage.waitForLoadState('networkidle');
    }

    // ----------------------------------------------------------------
    // Payment step — no Stripe keys in test mode, provisions directly
    // ----------------------------------------------------------------
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/payment|add payment method|trial/i, { timeout: 5000 });

    const paymentSubmit = registryPage.locator('button[type="submit"]').first();
    await expect(paymentSubmit).toBeVisible({ timeout: 10000 });
    await paymentSubmit.click();
    await registryPage.waitForLoadState('networkidle', { timeout: 15000 });

    // ----------------------------------------------------------------
    // Completion — assert welcome page rendered
    // ----------------------------------------------------------------
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/welcome to registry/i, { timeout: 10000 });

    // ----------------------------------------------------------------
    // Capture state.slug from the DB (do not derive in JS)
    // ----------------------------------------------------------------
    const slugRows = queryJson(testDB, 'registry', 'SELECT slug FROM tenants WHERE name = ?', state.orgName);
    expect(slugRows.length, 'tenant row exists in registry.tenants').toBeGreaterThan(0);
    state.slug = slugRows[0].slug;

    // Slug must be subdomain-routable: lowercase letters/digits/underscores, starts with a letter
    expect(state.slug, 'slug matches /^[a-z][a-z0-9_]+$/').toMatch(/^[a-z][a-z0-9_]+$/);

    // ----------------------------------------------------------------
    // Amara-in-tenant gate: Amara must exist in the tenant schema
    // ----------------------------------------------------------------
    const staffRows = queryJson(testDB, state.slug, 'SELECT id FROM users WHERE user_type = ?', 'staff');
    expect(staffRows.length, 'at least one staff user in tenant schema').toBeGreaterThan(0);
    state.amaraId = staffRows[0].id;

    const adminRows = queryJson(testDB, state.slug, 'SELECT id FROM users WHERE user_type = ?', 'admin');
    expect(adminRows.length, 'at least one admin user in tenant schema').toBeGreaterThan(0);
    state.morganId = adminRows[0].id;

    // ----------------------------------------------------------------
    // Workflows gate: tenant schema must include the workflows later legs need
    // ----------------------------------------------------------------
    const workflowRows = queryJson(testDB, state.slug, 'SELECT slug FROM workflows');
    const workflowSlugs = workflowRows.map(r => r.slug);
    expect(workflowSlugs, 'program-creation workflow exists').toContain('program-creation');
    expect(workflowSlugs, 'program-location-assignment workflow exists').toContain('program-location-assignment');
    expect(workflowSlugs, 'summer-camp-registration workflow exists').toContain('summer-camp-registration');
  });

});
