// ABOUTME: Base Playwright fixtures -- shared server + shared DB model.
// ABOUTME: Exposes the shared DB URL and a registryPage with helper methods.
const base = require('@playwright/test');
const fs = require('fs');
const path = require('path');

// __dirname here is t/playwright/fixtures/; the dotfile is written by
// global-setup.js to t/playwright/ (one level up).
const dbUrl = () =>
  fs.readFileSync(path.join(__dirname, '..', '.shared-db-url'), 'utf8').trim();

const test = base.test.extend({
  testDB: async ({}, use) => { await use({ dbUrl: dbUrl() }); },
  registryPage: async ({ page }, use) => {
    page.workflowUrl = (slug) => `/${slug}`;
    page.workflowRunStepUrl = (slug, runId, step) => `/${slug}/${runId}/${step}`;
    page.expectWorkflowLayout = async () => {
      await base.expect(page.locator('html')).toHaveAttribute('lang');
      await base.expect(page.locator('head meta[charset]')).toBeAttached();
      await base.expect(page.locator('script[src*="htmx"]')).toBeAttached();
    };
    page.expectUTF8Rendering = async () => {
      const emojis = await page.locator(
        'text=/[\\u{1F600}-\\u{1F64F}]|[\\u{1F300}-\\u{1F5FF}]|[\\u{1F680}-\\u{1F6FF}]|[\\u{1F1E0}-\\u{1F1FF}]/u'
      ).all();
      for (const e of emojis) { await base.expect(e).toBeVisible(); }
    };
    page.expectHTMXResponse = async (trigger, expected) => {
      await page.locator(trigger).click();
      await base.expect(page.locator(expected)).toBeVisible({ timeout: 5000 });
    };
    await use(page);
  },
});

module.exports = { test, expect: base.expect };
