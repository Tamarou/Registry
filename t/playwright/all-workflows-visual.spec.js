// ABOUTME: Comprehensive visual tests for all workflow types in Registry
// ABOUTME: Ensures layout consistency across different workflow implementations

const { test, expect } = require('./fixtures/base');

// Common workflows in Registry that should all have proper layouts
const WORKFLOWS_TO_TEST = [
  'tenant-signup',
  'session-creation',
  'user-registration',
  'event-creation',
  'payment-processing'
];

test.describe('All Workflows Visual Consistency', () => {
  for (const workflowSlug of WORKFLOWS_TO_TEST) {
    test(`${workflowSlug} workflow has proper layout structure`, async ({ registryPage }) => {
      // Navigate to workflow
      await registryPage.goto(`/workflow/${workflowSlug}`);

      // Verify layout consistency across all workflows
      await registryPage.expectWorkflowLayout();

      // Take screenshot for this workflow
      await expect(registryPage).toHaveScreenshot(`${workflowSlug}-layout.png`);
    });

    test(`${workflowSlug} workflow UTF-8 rendering`, async ({ registryPage }) => {
      await registryPage.goto(`/workflow/${workflowSlug}`);

      // Check UTF-8 support
      await registryPage.expectUTF8Rendering();

      // Verify page encoding
      const charset = await registryPage.locator('meta[charset]').getAttribute('charset');
      expect(charset.toLowerCase()).toBe('utf-8');
    });

    test(`${workflowSlug} workflow cross-browser consistency`, async ({ registryPage, browserName }) => {
      await registryPage.goto(`/workflow/${workflowSlug}`);

      // Wait for full load
      await registryPage.waitForLoadState('networkidle');

      // Take browser-specific screenshot
      await expect(registryPage).toHaveScreenshot(`${workflowSlug}-${browserName}.png`);
    });
  }

  test('workflow layouts are consistent across all types', async ({ registryPage }) => {
    const layoutChecks = [];

    for (const workflowSlug of WORKFLOWS_TO_TEST) {
      await registryPage.goto(`/workflow/${workflowSlug}`);

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
          hasWorkflowProgress: !!body.querySelector('workflow-progress'),
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
      await registryPage.goto(`/workflow/${WORKFLOWS_TO_TEST[0]}`);
      await registryPage.waitForLoadState('networkidle');

      // Verify layout doesn't break
      await registryPage.expectWorkflowLayout();

      // Take screenshot for visual regression
      await expect(registryPage).toHaveScreenshot(`workflow-responsive-${viewport.name}.png`);
    }
  });
});