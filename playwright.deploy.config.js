// ABOUTME: Playwright config for post-deploy validation against the LIVE production site.
// ABOUTME: Deliberately has no globalSetup -- it starts no database and no local server.

const { defineConfig, devices } = require('@playwright/test');

// This is a separate config rather than a project inside playwright.config.js
// because that config's globalSetup provisions a Test::PostgreSQL database and
// spawns `carton exec ./registry daemon`. Those are config-level, so they ran
// for every project -- including this one, in a job that installs no Perl, which
// is why deploy validation failed with `spawn carton ENOENT` before reaching a
// single assertion. Nothing here needs a local anything: the target is a URL.
module.exports = defineConfig({
  testDir: './t/playwright',
  testMatch: 'deploy-validation.spec.js',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  // The target is a live site over the public internet; a flake is not a defect.
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: [
    ['list'],
    ['junit', { outputFile: 'test-results/junit.xml' }],
  ],
  use: {
    baseURL: process.env.DEPLOY_VALIDATION_URL || 'https://tinyartempire.com',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
});
