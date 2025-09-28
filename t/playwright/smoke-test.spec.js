// ABOUTME: Basic smoke test to verify Playwright setup works correctly
// ABOUTME: Simple test to ensure basic functionality before running full suite

const { test, expect } = require('@playwright/test');

test.describe('Playwright Smoke Tests', () => {
  test('can load Registry homepage', async ({ page }) => {
    // Simple test without custom fixtures first
    await page.goto('/');

    // Just check that we get a response
    const title = await page.title();
    console.log('Page title:', title);

    // Basic assertions
    expect(title).toBeTruthy();
    await expect(page.locator('body')).toBeAttached();

    // Take a screenshot to verify
    await page.screenshot({ path: 'smoke-test.png' });
  });

  test('Registry server is responsive', async ({ page }) => {
    const response = await page.goto('/');
    expect(response.status()).toBeLessThan(500);
  });
});