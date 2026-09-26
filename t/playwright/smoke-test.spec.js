// ABOUTME: Basic smoke test to verify Playwright setup works correctly
// ABOUTME: Simple test to ensure basic functionality before running full suite

const { test, expect } = require('./fixtures/base');

test.describe('Playwright Smoke Tests', () => {
  test('can load Registry homepage', async ({ registryPage, testDB }) => {
    // Test uses the registryPage fixture which sets up database and server
    await registryPage.goto('/');

    // A non-empty title is true of the error page too, so the assertion names the
    // product. If the landing page is replaced this fails and should -- a smoke
    // test that cannot tell the homepage from a stack trace is not a smoke test.
    await expect(registryPage).toHaveTitle(/Tiny Art Empire/);
    await expect(registryPage.locator('body')).toBeAttached();
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Take a screenshot to verify
    await registryPage.screenshot({ path: 'smoke-test.png' });
  });

  test('Registry server is responsive', async ({ registryPage, testDB }) => {
    const response = await registryPage.goto('/');
    expect(response.status()).toBeLessThan(500);
  });
});