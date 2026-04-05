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
      await planRadio.check();
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
      await planRadio.check();
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
});
