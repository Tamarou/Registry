// ABOUTME: Base Playwright fixtures for Registry testing
// ABOUTME: Provides database setup, test data creation, and common utilities

const playwright = require('@playwright/test');
const base = playwright.test;
const expect = playwright.expect;
const { spawn, exec } = require('child_process');
const { promisify } = require('util');

const execAsync = promisify(exec);

// Database setup helper - mirrors Test::Registry::DB patterns
class TestDB {
  constructor() {
    this.dbName = `registry_test_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    this.dbUrl = `postgresql:///${this.dbName}`;
  }

  async setup() {
    // Create test database
    await execAsync(`createdb ${this.dbName}`);

    // Set environment for Registry app
    process.env.DB_URL = this.dbUrl;

    // Deploy schema
    await execAsync(`cd /home/perigrin/dev/Registry && DB_URL=${this.dbUrl} carton exec sqitch deploy`);

    // Import workflows and templates
    await execAsync(`cd /home/perigrin/dev/Registry && DB_URL=${this.dbUrl} carton exec ./registry workflow import registry`);
    await execAsync(`cd /home/perigrin/dev/Registry && DB_URL=${this.dbUrl} carton exec ./registry template import registry`);
  }

  async teardown() {
    try {
      await execAsync(`dropdb ${this.dbName}`);
    } catch (e) {
      // Database might already be dropped
    }
  }
}

// Fixtures following Registry test patterns
const test = base.extend({
  // Database fixture - automatic setup/teardown
  testDB: async ({}, use) => {
    const db = new TestDB();
    await db.setup();
    await use(db);
    await db.teardown();
  },

  // Page with Registry-specific helpers
  registryPage: async ({ page, testDB }, use) => {
    // Helper methods that mirror Test::Registry::Helpers
    page.workflowUrl = (workflowSlug) => `/workflow/${workflowSlug}`;
    page.workflowRunStepUrl = (workflowSlug, runId, stepSlug) => `/workflow/${workflowSlug}/run/${runId}/step/${stepSlug}`;

    // UTF-8 validation helper
    page.expectUTF8Rendering = async () => {
      // Check that emojis and special characters render correctly
      const emojiElements = await page.locator('text=/[\\u{1F600}-\\u{1F64F}]|[\\u{1F300}-\\u{1F5FF}]|[\\u{1F680}-\\u{1F6FF}]|[\\u{1F1E0}-\\u{1F1FF}]/u').all();
      for (const emoji of emojiElements) {
        await expect(emoji).toBeVisible();
      }
    };

    // Layout validation helper
    page.expectWorkflowLayout = async () => {
      // Verify essential layout elements
      await expect(page.locator('html')).toHaveAttribute('lang');
      await expect(page.locator('head meta[charset]')).toBeAttached();
      await expect(page.locator('head title')).toBeAttached();

      // Check for CSS inclusion
      const cssLinks = await page.locator('link[rel="stylesheet"]').count();
      expect(cssLinks).toBeGreaterThan(0);

      // Check for HTMX inclusion
      await expect(page.locator('script[src*="htmx"]')).toBeAttached();
    };

    // HTMX interaction helper
    page.expectHTMXResponse = async (triggerSelector, expectedSelector) => {
      await page.locator(triggerSelector).click();
      await expect(page.locator(expectedSelector)).toBeVisible({ timeout: 5000 });
    };

    await use(page);
  },
});

module.exports = { test, expect };