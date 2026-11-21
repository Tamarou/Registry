// ABOUTME: Playwright configuration for Registry visual and interaction testing
// ABOUTME: Configures browsers, timeouts, and test patterns for comprehensive UI testing

const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './t/playwright',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: [
    ['html'],
    ['junit', { outputFile: 'test-results/junit.xml' }],
    ['list']
  ],
  globalSetup: require.resolve('./t/playwright/global-setup.js'),
  globalTeardown: require.resolve('./t/playwright/global-teardown.js'),
  use: {
    baseURL: 'http://127.0.0.1:3001',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },

  // No webServer here: Playwright starts webServer BEFORE globalSetup, but our
  // server needs the DB that globalSetup provisions. globalSetup starts both the
  // DB and the server itself, in order.

  projects: [
    {
      name: 'chromium',
      // deploy-validation runs against the LIVE production site and belongs only
      // to its own project / the deploy-validation workflow -- never the PR e2e
      // gate, or every PR goes red whenever prod is unhealthy.
      testIgnore: 'deploy-validation.spec.js',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'firefox',
      testIgnore: 'deploy-validation.spec.js',
      use: { ...devices['Desktop Firefox'] },
    },
    // Production deploy validation -- runs against the live site, no test DB needed
    {
      name: 'deploy-validation',
      testMatch: 'deploy-validation.spec.js',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: process.env.DEPLOY_VALIDATION_URL || 'https://tinyartempire.com',
      },
    },
  ],
});