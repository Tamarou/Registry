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

  webServer: {
    command: 'bash t/playwright/start-test-server.sh',
    url: 'http://127.0.0.1:3001/health',
    reuseExistingServer: !process.env.CI,
    timeout: 120 * 1000,
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'firefox',
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