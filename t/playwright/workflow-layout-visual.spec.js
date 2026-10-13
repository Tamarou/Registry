// ABOUTME: Visual regression tests for workflow layout rendering
// ABOUTME: Ensures proper HTML structure, UTF-8 encoding, and styling across workflow pages

const { test, expect } = require('./fixtures/base');

test.describe('Workflow Layout Visual Tests', () => {
  test('workflow pages render with complete HTML structure', async ({ registryPage }) => {
    // Navigate to tenant signup workflow (matches the Issue #60 scenario)
    await registryPage.goto('/tenant-signup');

    // Verify complete HTML structure (would have failed before Issue #60 fix)
    await registryPage.expectWorkflowLayout();
  });

  test('UTF-8 and emoji rendering works correctly', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Check that emojis render properly (Issue #60 specific problem)
    await registryPage.expectUTF8Rendering();

    // Verify page has charset meta tag
    const charset = await registryPage.locator('meta[charset]').getAttribute('charset');
    expect(charset.toLowerCase()).toBe('utf-8');
  });

  test('the landing page shows no progress indicator', async ({ registryPage }) => {
    // tenant-signup ships a {slug}/index template, so Workflows#index returns
    // early and computes no progress for it. That is right: a landing page has
    // no progress to show yet.
    await registryPage.goto('/tenant-signup');

    await expect(registryPage.locator('h1')).toBeVisible();
    await expect(registryPage.locator('workflow-progress')).toHaveCount(0);
  });

  test('a workflow step shows which step you are on, and the component runs', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');
    expect(registryPage.url()).toContain('profile');

    const progress = registryPage.locator('workflow-progress');
    await expect(progress).toHaveCount(1);
    await expect(progress).toHaveAttribute('data-current-step', '2');
    await expect(progress).toHaveAttribute('data-total-steps', '5');

    // The point of asserting this in a browser rather than in Perl: only here
    // can we see that the custom element actually UPGRADED and rendered its
    // shadow root. Perl can prove the markup is on the page; it cannot prove the
    // 11K of script on every workflow page did anything, which was the whole of
    // #423.
    const nav = progress.locator('nav.progress-container');
    await expect(nav).toBeVisible();
    await expect(nav).toHaveAttribute('aria-label', 'Workflow progress');

    // One label per step, and the step you are on marked as such.
    await expect(progress.locator('.step')).toHaveCount(5);
    await expect(progress.locator('.step.current')).toHaveCount(1);
  });

  test('a completed step is reachable from the indicator', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    const progress = registryPage.locator('workflow-progress');
    await expect(progress).toHaveCount(1);

    // Only steps already behind you get a URL, which is what makes the labels
    // safe to click -- there is nothing to click forward to.
    const completed = progress.locator('.step.completed');
    await expect(completed).toHaveCount(1);

    // The component dispatches workflow-navigation and then assigns
    // location itself, so a click leaves the step page.
    await completed.first().click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
  });

  test('CSS styling loads and applies correctly', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Wait for CSS to load
    await registryPage.waitForLoadState('networkidle');

    // Check computed styles on key elements
    const header = registryPage.locator('h1').first();
    await expect(header).toHaveCSS('font-weight', '700'); // Assuming bold headers

    const mainContent = registryPage.locator('.workflow-content, main, .container').first();
    await expect(mainContent).toHaveCSS('display', /block|flex|grid/);
  });

  test('HTMX interactions work in workflow context', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Look for any HTMX-enabled forms or buttons
    const htmxElements = registryPage.locator('[hx-get], [hx-post], [hx-target]');
    const count = await htmxElements.count();

    if (count > 0) {
      // Test first HTMX interaction
      const firstHtmxElement = htmxElements.first();
      const targetSelector = await firstHtmxElement.getAttribute('hx-target') || 'body';

      await registryPage.expectHTMXResponse(
        firstHtmxElement,
        targetSelector
      );
    }
  });

  test('mobile responsive layout works correctly', async ({ registryPage }) => {
    // Set mobile viewport
    await registryPage.setViewportSize({ width: 375, height: 667 });
    await registryPage.goto('/tenant-signup');

    // Verify layout adapts to mobile
    await registryPage.expectWorkflowLayout();

    // Test that text is readable (not too small); allow decimal values like 19.2px
    const bodyText = registryPage.locator('body');
    await expect(bodyText).toHaveCSS('font-size', /1[4-9](\.[0-9]+)?px|[2-9][0-9](\.[0-9]+)?px/); // At least 14px
  });

  test('workflow navigation between steps works visually', async ({ registryPage }) => {
    // Start workflow
    await registryPage.goto('/tenant-signup');

    // Verify initial page has proper structure
    await registryPage.expectWorkflowLayout();

    // Try to navigate to next step (if form is present)
    const nextButton = registryPage.locator('button[type="submit"], input[type="submit"], .next-step');
    if (await nextButton.count() > 0) {
      await nextButton.first().click();
      await registryPage.waitForLoadState('networkidle');

      // Verify layout is still intact after navigation
      await registryPage.expectWorkflowLayout();
    }
  });
});
