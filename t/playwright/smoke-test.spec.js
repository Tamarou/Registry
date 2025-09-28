// ABOUTME: Basic smoke test to verify Playwright setup works correctly
// ABOUTME: Simple test to ensure basic functionality before running full suite

const { test, expect } = require('./fixtures/base');

test.describe('Playwright Smoke Tests', () => {
  test('can load Registry homepage', async ({ registryPage, testDB }) => {
    // Test uses the registryPage fixture which sets up database and server
    await registryPage.goto('/');

    // Just check that we get a response
    const title = await registryPage.title();
    console.log('Page title:', title);

    // Basic assertions
    expect(title).toBeTruthy();
    await expect(registryPage.locator('body')).toBeAttached();

    // Take a screenshot to verify
    await registryPage.screenshot({ path: 'smoke-test.png' });
  });

  test('Registry server is responsive', async ({ registryPage, testDB }) => {
    const response = await registryPage.goto('/');
    expect(response.status()).toBeLessThan(500);
  });
});