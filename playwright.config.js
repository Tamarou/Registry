// ABOUTME: Playwright configuration for Registry visual and interaction testing
// ABOUTME: Configures browsers, timeouts, and test patterns for comprehensive UI testing

const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './t/playwright',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [
    ['html'],
    ['junit', { outputFile: 'test-results/junit.xml' }],
    ['list']
  ],
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
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
    // Commented out webkit and mobile browsers to avoid missing system dependencies
    // These can be re-enabled once proper browser dependencies are installed
    // {
    //   name: 'webkit',
    //   use: { ...devices['Desktop Safari'] },
    // },
    // {
    //   name: 'mobile-chrome',
    //   use: { ...devices['Pixel 5'] },
    // },
    // {
    //   name: 'mobile-safari',
    //   use: { ...devices['iPhone 12'] },
    // },
  ],

  // webServer configuration disabled for now - tests will manage their own database setup
  // webServer: {
  //   command: 'make dev-server',
  //   port: 3001,
  //   reuseExistingServer: true,
  //   timeout: 120 * 1000,
  // },
});