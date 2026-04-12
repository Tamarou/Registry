// ABOUTME: Post-deploy browser validation tests against the live production site.
// ABOUTME: Verifies rendering, styling, content, encoding, and CTA functionality after deployment.

const { test, expect } = require('@playwright/test');

// These tests run against the live site -- no testDB or registryPage fixtures.
// Use the DEPLOY_VALIDATION_URL env var or default to tinyartempire.com.
const BASE_URL = process.env.DEPLOY_VALIDATION_URL || 'https://tinyartempire.com';

test.describe.configure({ timeout: 60000 });

test.describe('Deploy validation: Jordan landing page', () => {

  test('landing page loads with vaporwave design system', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('networkidle');

    // Page loads without server error
    await expect(page.locator('body')).not.toContainText('Internal Server Error');

    // Design system renders
    await expect(page.locator('.landing-page')).toBeVisible();
    await expect(page.locator('.landing-hero')).toBeVisible();

    // CSS loaded
    const themeCss = await page.locator('link[rel="stylesheet"][href*="theme.css"]').count();
    expect(themeCss).toBeGreaterThan(0);
    const appCss = await page.locator('link[rel="stylesheet"][href*="app.css"]').count();
    expect(appCss).toBeGreaterThan(0);
  });

  test('hero section renders with correct copy', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('networkidle');

    await expect(page.locator('.landing-hero h1')).toContainText('Your art deserves a real business');
    await expect(page.locator('.landing-hero-subtitle').first()).toContainText('get back to making art');
  });

  test('problem cards render (6 cards)', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('networkidle');

    await expect(page.locator('.landing-features h2').first()).toContainText('Less paperwork');

    const cards = page.locator('.landing-feature-card');
    await expect(cards).toHaveCount(6);
  });

  test('alignment section shows pricing', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('networkidle');

    await expect(page.locator('body')).toContainText('2.5%');
    await expect(page.locator('body')).toContainText('Free to Start');
  });

  test('no UTF-8 encoding issues', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('networkidle');

    // No mojibake markers
    await expect(page.locator('body')).not.toContainText('\uFFFD');
    await expect(page.locator('body')).not.toContainText('â€"');
    await expect(page.locator('body')).not.toContainText('â€™');
  });

  test('Get Started CTA navigates to tenant-signup', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('networkidle');

    const cta = page.locator('.landing-cta-button').first();
    await expect(cta).toBeVisible();
    await expect(cta).toContainText('Get Started');

    await cta.click();
    await page.waitForLoadState('networkidle');

    expect(page.url()).toContain('tenant-signup');
    await expect(page.locator('body')).not.toContainText('Internal Server Error');
  });

  test('mobile viewport renders correctly', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto(BASE_URL);
    await page.waitForLoadState('networkidle');

    await expect(page.locator('.landing-hero h1')).toBeVisible();
    await expect(page.locator('.landing-cta-button').first()).toBeVisible();
  });
});

test.describe('Deploy validation: tenant-signup workflow', () => {

  test('tenant-signup landing page loads', async ({ page }) => {
    await page.goto(`${BASE_URL}/tenant-signup`);
    await page.waitForLoadState('networkidle');

    await expect(page.locator('body')).not.toContainText('Internal Server Error');
    await expect(page.locator('h1, h2').first()).toBeVisible();
  });

  test('no UTF-8 mojibake in signup workflow', async ({ page }) => {
    await page.goto(`${BASE_URL}/tenant-signup`);
    await page.waitForLoadState('networkidle');

    // Check for the common mojibake pattern from arrow characters
    const bodyText = await page.locator('body').innerText();
    expect(bodyText).not.toContain('â');
  });
});
