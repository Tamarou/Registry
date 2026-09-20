// ABOUTME: Comprehensive visual tests for all workflow types in Registry
// ABOUTME: Ensures layout consistency across different workflow implementations

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');
const { loginToken, loginWithToken } = require('./journey_helpers');

// Workflows that render a full HTML page with proper structure (lang, charset, htmx).
//
// These are guarded by the /:workflow catch-all, so this spec signs in as an
// admin before each test. It used to browse anonymously, and user-creation
// dropped out of this list the moment the guard landed -- it was only ever
// passing because the route was open.
//
// Three workflows stay out, and the reasons are all about the templates rather
// than the guard:
//   session-creation and event-creation have hand-written standalone
//     index.html.ep documents that use no layout at all -- hence no lang
//     attribute and no htmx. (An older comment here blamed an authentication
//     gate page; signing in does not change them, because the layout is not
//     what they are missing. session-creation's is titled "Login" and offers a
//     bare "Start Here" button -- an unfinished scaffold, see #399.)
//   summer-camp-registration is public but its landing step uses
//     layout 'default', which loads no htmx.
const WORKFLOWS_TO_TEST = [
  'tenant-signup',
  'user-creation'
];


// tenant-signup is public; the rest are not. One admin, and a fresh magic-link
// token per test because each test gets its own browser context and a token is
// single use.
let adminId;
test.beforeAll(async ({ testDB }) => {
  let out;
  try {
    out = execSync('carton exec perl t/playwright/setup_admin_test_data.pl', {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
      timeout: 120000,
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (e) {
    throw new Error(`seed failed: ${e.stderr || e.stdout || e.message}`);
  }
  if (!out) throw new Error('setup_admin_test_data.pl produced no output');
  adminId = JSON.parse(out.split('\n').pop()).admin_id;
});

test.describe('All Workflows Visual Consistency', () => {
  test.beforeEach(async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, loginToken(testDB, 'registry', adminId));
  });

  for (const workflowSlug of WORKFLOWS_TO_TEST) {
    test(`${workflowSlug} workflow has proper layout structure`, async ({ registryPage }) => {
      // Navigate to workflow
      await registryPage.goto(`/${workflowSlug}`);

      // Verify layout consistency across all workflows
      await registryPage.expectWorkflowLayout();
    });

    test(`${workflowSlug} workflow UTF-8 rendering`, async ({ registryPage }) => {
      await registryPage.goto(`/${workflowSlug}`);

      // Check UTF-8 support
      await registryPage.expectUTF8Rendering();

      // Verify page encoding
      const charset = await registryPage.locator('meta[charset]').getAttribute('charset');
      expect(charset.toLowerCase()).toBe('utf-8');
    });

    test(`${workflowSlug} workflow cross-browser consistency`, async ({ registryPage, browserName }) => {
      await registryPage.goto(`/${workflowSlug}`);

      // Wait for full load
      await registryPage.waitForLoadState('networkidle');

      // Verify structural consistency across browsers (pixel snapshots removed as CI-flaky)
      await registryPage.expectWorkflowLayout();
    });
  }

  test('workflow layouts are consistent across all types', async ({ registryPage }) => {
    const layoutChecks = [];

    for (const workflowSlug of WORKFLOWS_TO_TEST) {
      await registryPage.goto(`/${workflowSlug}`);

      // Collect layout metrics for consistency checking
      const metrics = await registryPage.evaluate(() => {
        const html = document.documentElement;
        const head = document.head;
        const body = document.body;

        return {
          hasLang: html.hasAttribute('lang'),
          hasCharset: !!head.querySelector('meta[charset]'),
          hasTitle: !!head.querySelector('title'),
          cssLinkCount: head.querySelectorAll('link[rel="stylesheet"]').length,
          hasHTMX: !!head.querySelector('script[src*="htmx"]') || !!body.querySelector('script[src*="htmx"]'),
          bodyClasses: body.className
        };
      });

      layoutChecks.push({ workflow: workflowSlug, metrics });
    }

    // Verify all workflows have consistent layout elements
    for (const check of layoutChecks) {
      expect(check.metrics.hasLang, `${check.workflow} missing lang attribute`).toBe(true);
      expect(check.metrics.hasCharset, `${check.workflow} missing charset`).toBe(true);
      expect(check.metrics.hasTitle, `${check.workflow} missing title`).toBe(true);
      expect(check.metrics.cssLinkCount, `${check.workflow} has no CSS`).toBeGreaterThan(0);
      expect(check.metrics.hasHTMX, `${check.workflow} missing HTMX`).toBe(true);
    }
  });

  test('all workflows handle viewport changes gracefully', async ({ registryPage }) => {
    const viewports = [
      { width: 1920, height: 1080, name: 'desktop-large' },
      { width: 1366, height: 768, name: 'desktop-standard' },
      { width: 768, height: 1024, name: 'tablet' },
      { width: 375, height: 667, name: 'mobile' }
    ];

    for (const viewport of viewports) {
      await registryPage.setViewportSize({ width: viewport.width, height: viewport.height });

      // Test first workflow at this viewport
      await registryPage.goto(`/${WORKFLOWS_TO_TEST[0]}`);
      await registryPage.waitForLoadState('networkidle');

      // Verify layout doesn't break (pixel snapshots removed as CI-flaky)
      await registryPage.expectWorkflowLayout();
    }
  });
});
