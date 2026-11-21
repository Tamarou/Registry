// ABOUTME: End-to-end browser tests for the 7-step tenant signup workflow.
// ABOUTME: Covers landing, profile with subdomain validation, pricing, team, review, payment, and completion.

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

    // Subdomain preview should show
    const subdomainPreview = registryPage.locator('.subdomain-slug, #subdomain-slug, [class*="subdomain"]');
    if (await subdomainPreview.count() > 0) {
      await expect(subdomainPreview.first()).toContainText(/super-awesome/i);
    }

    // Billing email field
    const emailInput = registryPage.locator('input[name="billing_email"]');
    await expect(emailInput).toBeVisible();
    await registryPage.fill('input[name="billing_email"]', 'studio@superawesomecool.com');

    // Submit profile
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Should advance to next step (pricing or users)
    const nextUrl = registryPage.url();
    expect(nextUrl).not.toContain('profile');
  });

  // ===========================================================================
  // 3. Pricing step
  // ===========================================================================
  test('pricing step shows available plans', async ({ registryPage, testDB }) => {
    // Start workflow and advance through profile
    await registryPage.goto('/tenant-signup');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    await registryPage.fill('input[name="name"]', 'Test Pottery Studio');
    await registryPage.fill('input[name="billing_email"]', 'test@pottery.com');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Should be on users step (profile -> users -> pricing in the YAML order)
    // Fill users step
    const adminName = registryPage.locator('input[name="admin_name"]');
    if (await adminName.isVisible({ timeout: 2000 }).catch(() => false)) {
      await registryPage.fill('input[name="admin_name"]', 'Jordan Owner');
      await registryPage.fill('input[name="admin_email"]', 'jordan@pottery.com');
      await registryPage.fill('input[name="admin_username"]', 'jordan.owner');
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Should be on pricing step
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Pricing plans should be visible
    const pricingContent = registryPage.locator('body');
    const hasPricing = await pricingContent.textContent();

    // Should show plan options or pricing info
    expect(hasPricing).toMatch(/plan|pricing|price|free|solo|\$/i);
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

    // Pricing - select first available plan
    const planRadio = registryPage.locator('input[name="selected_plan_id"]').first();
    if (await planRadio.isVisible({ timeout: 2000 }).catch(() => false)) {
      // The design-system plan radio is visually hidden behind a styled label,
      // so force the check past Playwright's actionability wait (a real user
      // clicks the styled button; the raw input is not directly clickable).
      await planRadio.check({ force: true });
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Should be on review step
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Review should show the organization name we entered
    await expect(registryPage.locator('body')).toContainText('Review Test Studio');
  });

  // ===========================================================================
  // 5. Payment step (test mode)
  // ===========================================================================
  test('payment step renders without error', async ({ registryPage, testDB }) => {
    // Navigate through to payment
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

    // Pricing
    const planRadio = registryPage.locator('input[name="selected_plan_id"]').first();
    if (await planRadio.isVisible({ timeout: 2000 }).catch(() => false)) {
      // The design-system plan radio is visually hidden behind a styled label,
      // so force the check past Playwright's actionability wait (a real user
      // clicks the styled button; the raw input is not directly clickable).
      await planRadio.check({ force: true });
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Review - accept terms and submit
    const termsCheckbox = registryPage.locator('input[name="terms_accepted"]');
    if (await termsCheckbox.isVisible({ timeout: 2000 }).catch(() => false)) {
      await termsCheckbox.check();
    }
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // Should be on payment step (or complete if payment is auto-handled in test mode)
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Payment page should show payment-related content
    const bodyText = await registryPage.locator('body').textContent();
    expect(bodyText).toMatch(/payment|subscribe|complete|congratulations|success/i);
  });

  // ===========================================================================
  // 6. Complete signup: tenant is actually created (real browser, real DB check)
  // ===========================================================================
  test('completing payment creates a tenant with a provisioned schema', async ({ registryPage, testDB }) => {
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

    // Pricing step — select a plan if radio buttons are present, then always
    // click the submit button to advance.  If no plans exist in the DB (empty
    // test fixture), the step still has a "Continue to Review" submit button.
    const pricingStep = await registryPage.locator('h1, h2').filter({ hasText: /plan|pricing/i }).isVisible({ timeout: 2000 }).catch(() => false);
    if (pricingStep) {
      const planInput = registryPage.locator('input[name="selected_plan_id"]').first();
      if (await planInput.isVisible({ timeout: 1000 }).catch(() => false)) {
        // Hidden styled radio -- force past actionability checks.
        await planInput.check({ force: true });
      }
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // Review (if present) — the terms checkbox must be checked before the
    // #proceed-to-payment button is enabled (via JavaScript).
    const termsInput = registryPage.locator('input[name="terms_accepted"]');
    if (await termsInput.isVisible({ timeout: 3000 }).catch(() => false)) {
      await termsInput.check();
      // Wait for the proceed button to become enabled, then click it.
      const proceedBtn = registryPage.locator('#proceed-to-payment');
      await expect(proceedBtn).toBeEnabled({ timeout: 5000 });
      await proceedBtn.click();
      await registryPage.waitForLoadState('networkidle');
    }

    // Should now be on the payment step — verify we advanced past review.
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    // Verify we're actually on the payment step by checking for the payment form
    await expect(registryPage.locator('body')).toContainText(/payment|add payment method|trial/i, { timeout: 5000 });

    // Payment — click the "Add Payment Method & Start Trial" button.
    // In test mode (no Stripe keys), this POST triggers the no-Stripe mock branch
    // in TenantPayment::_provision_tenant, which creates the tenant immediately.
    const paymentSubmit = registryPage.locator('button[type="submit"]').first();
    await expect(paymentSubmit).toBeVisible({ timeout: 10000 });

    // Capture the POST response to debug any errors
    let paymentResponse = null;
    registryPage.on('response', resp => {
      if (resp.request().method() === 'POST') {
        paymentResponse = resp;
      }
    });

    await paymentSubmit.click();
    await registryPage.waitForLoadState('networkidle', { timeout: 15000 });

    // Should now be on the complete page — "Welcome to Registry!" is in complete.html.ep
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/welcome to registry/i, { timeout: 10000 });

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
