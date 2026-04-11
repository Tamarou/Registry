// ABOUTME: End-to-end browser test for Jordan's landing page journey on tinyartempire.com.
// ABOUTME: Verifies the registry tenant storefront renders correctly and the CTA flows into tenant-signup.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

test.describe.configure({ mode: 'serial', timeout: 120000 });

function seedRegistryStorefront(dbUrl) {
  const result = execSync(
    'carton exec perl t/playwright/setup_jordan_landing_data.pl',
    { cwd: process.cwd(), encoding: 'utf8', env: { ...process.env, DB_URL: dbUrl } }
  );
  const data = JSON.parse(result.trim());
  if (data.status !== 'seeded') {
    throw new Error(`Seeding failed: ${result}`);
  }
  return data;
}

test.describe("Jordan's landing page journey", () => {

  // ===========================================================================
  // 1. Landing page renders with vaporwave design
  // ===========================================================================
  test('landing page renders with vaporwave styling', async ({ registryPage, testDB }) => {
    seedRegistryStorefront(testDB.dbUrl);

    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('.landing-page')).toBeVisible();
    await expect(registryPage.locator('.landing-hero')).toBeVisible();

    const cssLinks = await registryPage.locator('link[rel="stylesheet"][href*="theme.css"]').count();
    expect(cssLinks).toBeGreaterThan(0);

    // No UTF-8 encoding issues (mojibake, replacement chars, double-encoding)
    await expect(registryPage.locator('body')).not.toContainText('\uFFFD'); // replacement character
    await expect(registryPage.locator('body')).not.toContainText('â€"');   // double-encoded em dash
    await expect(registryPage.locator('body')).not.toContainText('â€™');   // double-encoded apostrophe
  });

  // ===========================================================================
  // 2. Hero section has correct copy and CTA
  // ===========================================================================
  test('hero section shows headline and Get Started CTA', async ({ registryPage, testDB }) => {
    seedRegistryStorefront(testDB.dbUrl);

    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('.landing-hero h1')).toContainText('Your art deserves a real business');
    await expect(registryPage.locator('.landing-hero-subtitle').first()).toContainText('get back to making art');

    const cta = registryPage.locator('.landing-cta-button').first();
    await expect(cta).toBeVisible();
    await expect(cta).toContainText('Get Started');
  });

  // ===========================================================================
  // 3. Problem cards section renders all 6 cards
  // ===========================================================================
  test('problem cards section shows 6 cards', async ({ registryPage, testDB }) => {
    seedRegistryStorefront(testDB.dbUrl);

    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('.landing-features h2').first()).toContainText('Less paperwork');

    const cards = registryPage.locator('.landing-feature-card');
    await expect(cards).toHaveCount(6);

    await expect(cards.nth(0)).toContainText('Fill your classes');
    await expect(cards.nth(1)).toContainText('Get paid');
    await expect(cards.nth(2)).toContainText('One place');
    await expect(cards.nth(3)).toContainText('parents in the loop');
    await expect(cards.nth(4)).toContainText('how your business is doing');
    await expect(cards.nth(5)).toContainText('Grow when');
  });

  // ===========================================================================
  // 4. Alignment section shows pricing
  // ===========================================================================
  test('alignment section shows revenue share pricing', async ({ registryPage, testDB }) => {
    seedRegistryStorefront(testDB.dbUrl);

    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    const headings = registryPage.locator('.landing-features h2');
    await expect(headings.last()).toContainText('Free to Start');

    await expect(registryPage.locator('body')).toContainText('2.5% revenue share');
    await expect(registryPage.locator('body')).toContainText('no monthly fees');
  });

  // ===========================================================================
  // 5. No raw infrastructure data visible
  // ===========================================================================
  test('no raw session data exposed to Jordan', async ({ registryPage, testDB }) => {
    seedRegistryStorefront(testDB.dbUrl);

    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('999999');
    await expect(registryPage.locator('body')).not.toContainText('2036-01-01');
    await expect(registryPage.locator('body')).not.toContainText('spots left');
  });

  // ===========================================================================
  // 6. CTA clicks through to tenant-signup workflow
  // ===========================================================================
  test('Get Started CTA navigates to tenant-signup', async ({ registryPage, testDB }) => {
    seedRegistryStorefront(testDB.dbUrl);

    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    const cta = registryPage.locator('.landing-cta-button').first();
    await cta.click();
    await registryPage.waitForLoadState('networkidle');

    const url = registryPage.url();
    expect(url).toContain('tenant-signup');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
  });

  // ===========================================================================
  // 7. Mobile viewport renders correctly
  // ===========================================================================
  test('landing page is responsive on mobile', async ({ registryPage, testDB }) => {
    seedRegistryStorefront(testDB.dbUrl);

    await registryPage.setViewportSize({ width: 375, height: 812 });

    await registryPage.goto('/');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('.landing-hero h1')).toBeVisible();

    const cta = registryPage.locator('.landing-cta-button').first();
    await expect(cta).toBeVisible();

    const firstCard = registryPage.locator('.landing-feature-card').first();
    await expect(firstCard).toBeVisible();
  });
});
