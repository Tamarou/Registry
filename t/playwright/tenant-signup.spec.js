// ABOUTME: End-to-end browser tests for the 5-step tenant signup workflow.
// ABOUTME: Covers landing, profile with subdomain validation, team, review-and-create, and completion.

const { test, expect } = require('./fixtures/base');

// Run tests serially -- each test builds on the prior step.
test.describe.configure({ mode: 'serial', timeout: 120000 });

// ===========================================================================
// 1. Landing page
// ===========================================================================
test.describe('Tenant signup workflow', () => {
  test('landing page renders with begin button', async ({ registryPage, testDB }) => {
    await registryPage.goto('/tenant-signup');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Has a heading about signup/onboarding
    await expect(registryPage.locator('h1, h2').first()).toContainText(/sign up|onboard|get started|welcome/i);

    // Has a begin/start/continue button
    const submitBtn = registryPage.locator('button[type="submit"], a:has-text("Begin"), a:has-text("Start")');
    await expect(submitBtn.first()).toBeVisible();
  });

  // ===========================================================================
  // 2. Profile step with subdomain validation
  // ===========================================================================
  test('profile step accepts organization name and shows subdomain preview', async ({ registryPage, testDB }) => {
    // Navigate to tenant-signup and start the workflow
    await registryPage.goto('/tenant-signup');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Should be on the profile step
    const url = registryPage.url();
    expect(url).toContain('profile');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Organization name field exists
    const nameInput = registryPage.locator('input[name="name"]');
    await expect(nameInput).toBeVisible();

    // Fill in organization name
    await registryPage.fill('input[name="name"]', 'Super Awesome Cool Pottery');

    // Wait for subdomain preview to update (HTMX or JS)
    await registryPage.waitForTimeout(1500);

    // Required, not conditional. The preview is the only thing telling the tenant
    // what address they are about to be given, and the branch this replaces passed
    // when it was missing -- so a broken preview looked like a working one.
    const subdomainPreview = registryPage.locator('.subdomain-slug, #subdomain-slug, [class*="subdomain"]');
    await expect(subdomainPreview.first(), 'the subdomain preview is on screen')
      .toBeVisible({ timeout: 10000 });
    await expect(subdomainPreview.first(), 'and shows the address derived from the name')
      .toContainText(/super-awesome/i);

    // Billing email field
    const emailInput = registryPage.locator('input[name="billing_email"]');
    await expect(emailInput).toBeVisible();
    await registryPage.fill('input[name="billing_email"]', 'studio@superawesomecool.com');

    // Submit profile
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Should advance to the users step
    const nextUrl = registryPage.url();
    expect(nextUrl).not.toContain('profile');
  });

  // ===========================================================================
  // 3. The plan reaches the applicant without being chosen
  // ===========================================================================
  test('review step quotes the plan nobody was asked to pick', async ({ registryPage, testDB }) => {
    // Start workflow and advance through profile
    await registryPage.goto('/tenant-signup');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    await registryPage.fill('input[name="name"]', 'Test Pottery Studio');
    await registryPage.fill('input[name="billing_email"]', 'test@pottery.com');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Users step
    const adminName = registryPage.locator('input[name="admin_name"]');
    if (await adminName.isVisible({ timeout: 2000 }).catch(() => false)) {
      await registryPage.fill('input[name="admin_name"]', 'Jordan Owner');
      await registryPage.fill('input[name="admin_email"]', 'jordan@pottery.com');
      await registryPage.fill('input[name="admin_username"]', 'jordan.owner');
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Straight to review. Nothing asks which plan, and nothing asks for a card,
    // so the terms the applicant is agreeing to have to be on this page.
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    expect(registryPage.url()).toContain('/review');

    const bodyText = await registryPage.locator('body').textContent();
    expect(bodyText).toMatch(/solo/i);
    expect(bodyText).toMatch(/% of the payments/i);
    // The page must not promise a trial: Solo is free and stays free.
    expect(bodyText).not.toMatch(/free trial/i);
  });

  // ===========================================================================
  // 4. Review step shows all collected data
  // ===========================================================================
  test('review step displays organization and team details', async ({ registryPage, testDB }) => {
    // Start workflow and advance through all steps to review
    await registryPage.goto('/tenant-signup');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Profile
    await registryPage.fill('input[name="name"]', 'Review Test Studio');
    await registryPage.fill('input[name="billing_email"]', 'review@test.com');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Users
    const adminName = registryPage.locator('input[name="admin_name"]');
    if (await adminName.isVisible({ timeout: 2000 }).catch(() => false)) {
      await registryPage.fill('input[name="admin_name"]', 'Admin User');
      await registryPage.fill('input[name="admin_email"]', 'admin@test.com');
      await registryPage.fill('input[name="admin_username"]', 'admin.user');
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Should be on review step
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Review should show the organization name we entered
    await expect(registryPage.locator('body')).toContainText('Review Test Studio');
  });

  // ===========================================================================
  // 5. Review is the last page before completion
  // ===========================================================================
  test('accepting terms on review goes straight to completion', async ({ registryPage, testDB }) => {
    await registryPage.goto('/tenant-signup');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Profile
    await registryPage.fill('input[name="name"]', 'Payment Test Studio');
    await registryPage.fill('input[name="billing_email"]', 'pay@test.com');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Users
    const adminName = registryPage.locator('input[name="admin_name"]');
    if (await adminName.isVisible({ timeout: 2000 }).catch(() => false)) {
      await registryPage.fill('input[name="admin_name"]', 'Pay Admin');
      await registryPage.fill('input[name="admin_email"]', 'payadmin@test.com');
      await registryPage.fill('input[name="admin_username"]', 'pay.admin');
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Review - accept terms and create
    const termsCheckbox = registryPage.locator('input[name="terms_accepted"]');
    await expect(termsCheckbox).toBeVisible({ timeout: 5000 });
    await termsCheckbox.check();
    const createBtn = registryPage.locator('#create-studio');
    await expect(createBtn).toBeEnabled({ timeout: 5000 });
    await createBtn.click();
    await registryPage.waitForLoadState('networkidle', { timeout: 15000 });

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    // No card was collected on the way here, and none is asked for now.
    expect(registryPage.url()).toContain('/complete');
    const bodyText = await registryPage.locator('body').textContent();
    expect(bodyText).toMatch(/your studio is live/i);
    expect(bodyText).not.toMatch(/free trial/i);
  });

  // ===========================================================================
  // 6. Complete signup: tenant is actually created (real browser, real DB check)
  // ===========================================================================
  test('creating the studio provisions a tenant with a schema', async ({ registryPage, testDB }) => {
    const { spawnSync } = require('child_process');
    // Unique per run: CI runs chromium AND firefox against the SAME shared DB,
    // so a fixed slug collides on tenants_slug_key. The suffix keeps each run's
    // tenant distinct.
    const suffix = `${Date.now()}`;
    const orgName = `E2E Verify ${suffix}`;
    // Slug normalization: lowercased, spaces/hyphens -> underscores.
    const expectedSlug = `e2e_verify_${suffix}`;

    // Clear session cookies so this test always gets a fresh workflow run
    // (prior serial tests may have left an incomplete run in the session).
    await registryPage.context().clearCookies();

    // --- Drive the full workflow ---
    await registryPage.goto('/tenant-signup');
    await registryPage.waitForLoadState('networkidle');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Profile
    await expect(registryPage.locator('input[name="name"]')).toBeVisible({ timeout: 5000 });
    await registryPage.fill('input[name="name"]', orgName);
    await registryPage.fill('input[name="billing_email"]', 'e2everify@test.com');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Users (if present)
    const adminNameInput = registryPage.locator('input[name="admin_name"]');
    if (await adminNameInput.isVisible({ timeout: 3000 }).catch(() => false)) {
      await registryPage.fill('input[name="admin_name"]', 'E2E Admin');
      await registryPage.fill('input[name="admin_email"]', 'e2eadmin@test.com');
      await registryPage.fill('input[name="admin_username"]', 'e2eadmin');
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Review — the terms checkbox must be checked before #create-studio is
    // enabled (via JavaScript), and that button is what provisions the tenant.
    const termsInput = registryPage.locator('input[name="terms_accepted"]');
    await expect(termsInput).toBeVisible({ timeout: 5000 });
    await termsInput.check();
    const createBtn = registryPage.locator('#create-studio');
    await expect(createBtn).toBeEnabled({ timeout: 5000 });

    // Capture the POST response to debug any errors
    let createResponse = null;
    registryPage.on('response', resp => {
      if (resp.request().method() === 'POST') {
        createResponse = resp;
      }
    });

    await createBtn.click();
    await registryPage.waitForLoadState('networkidle', { timeout: 15000 });

    // Should now be on the complete page.
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/your studio is live/i, { timeout: 10000 });

    // --- Verify tenant was actually created in the DB ---
    // Use psql to query the shared test DB (no node pg driver needed).
    const dbUrl = testDB.dbUrl;

    const tenantCheck = spawnSync('psql', [
      dbUrl,
      '-t', '-A',
      '-c', `SELECT COUNT(*) FROM registry.tenants WHERE slug = '${expectedSlug}'`
    ], { cwd: process.cwd(), encoding: 'utf8' });

    const tenantCount = parseInt(tenantCheck.stdout.trim(), 10);
    expect(tenantCount, 'tenant row exists in registry.tenants').toBeGreaterThan(0);

    // Verify the tenant schema has its workflows table populated
    const schemaCheck = spawnSync('psql', [
      dbUrl,
      '-t', '-A',
      '-c', `SELECT COUNT(*) FROM "${expectedSlug}".workflows`
    ], { cwd: process.cwd(), encoding: 'utf8' });

    const workflowCount = parseInt(schemaCheck.stdout.trim(), 10);
    expect(workflowCount, 'tenant schema workflows table is populated').toBeGreaterThan(0);
  });
});
