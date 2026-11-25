// ABOUTME: Base Playwright fixtures -- shared server + shared DB model.
// ABOUTME: Exposes the shared DB URL and a registryPage with helper methods.
const base = require('@playwright/test');
const dns = require('dns');
const fs = require('fs');
const path = require('path');

// RFC 6761: every *.localhost name is loopback. The browser hard-codes that, but
// page.request runs in Node, which asks the system resolver -- and only
// systemd-resolved (CI's runner) answers for tenant subdomains. Anywhere else a
// page.request to `${slug}.localhost` died with getaddrinfo ENOTFOUND.
const lookup = dns.promises.lookup;
dns.promises.lookup = (host, ...rest) =>
  lookup(/\.localhost\.?$/i.test(host) ? 'localhost' : host, ...rest);

// The layouts load htmx from unpkg. Serve the same pinned release from
// node_modules so the suite never depends on reaching a CDN: where it was
// blocked, every hx-* control was dead and the failures looked like app bugs.
// Keep the htmx.org devDependency in step with the version in the layouts.
const HTMX_URL = 'https://unpkg.com/htmx.org@2.0.3';
const HTMX_FILE = require.resolve('htmx.org/dist/htmx.min.js');

// __dirname here is t/playwright/fixtures/; the dotfile is written by
// global-setup.js to t/playwright/ (one level up).
const dbUrl = () =>
  fs.readFileSync(path.join(__dirname, '..', '.shared-db-url'), 'utf8').trim();

const test = base.test.extend({
  context: async ({ context }, use) => {
    await context.route(HTMX_URL, (route) => route.fulfill({ path: HTMX_FILE }));
    await use(context);
  },
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
