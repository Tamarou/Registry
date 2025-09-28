// ABOUTME: Visual regression tests for workflow layout rendering
// ABOUTME: Ensures proper HTML structure, UTF-8 encoding, and styling across workflow pages

const { test, expect } = require('./fixtures/base');

test.describe('Workflow Layout Visual Tests', () => {
  test('workflow pages render with complete HTML structure', async ({ registryPage }) => {
    // Navigate to tenant signup workflow (matches the Issue #60 scenario)
    await registryPage.goto('/workflow/tenant-signup');

    // Verify complete HTML structure (would have failed before Issue #60 fix)
    await registryPage.expectWorkflowLayout();

    // Take screenshot for visual regression
    await expect(registryPage).toHaveScreenshot('tenant-signup-layout.png');
  });

  test('UTF-8 and emoji rendering works correctly', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

    // Check that emojis render properly (Issue #60 specific problem)
    await registryPage.expectUTF8Rendering();

    // Verify specific emojis that appear in the signup flow
    await expect(registryPage.locator('text=/📅/')).toBeVisible();
    await expect(registryPage.locator('text=/🔒/')).toBeVisible();
    await expect(registryPage.locator('text=/💡/')).toBeVisible();

    // Take screenshot focusing on emoji rendering
    await expect(registryPage.locator('.workflow-content')).toHaveScreenshot('emoji-rendering.png');
  });

  test('workflow progress indicator displays correctly', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

    // Check that workflow progress component is present and functional
    const progressComponent = registryPage.locator('workflow-progress');
    await expect(progressComponent).toBeAttached();

    // Verify progress data attributes are set
    await expect(progressComponent).toHaveAttribute('data-current-step');
    await expect(progressComponent).toHaveAttribute('data-total-steps');
    await expect(progressComponent).toHaveAttribute('data-step-names');

    // Take screenshot of progress indicator
    await expect(progressComponent).toHaveScreenshot('workflow-progress.png');
  });

  test('CSS styling loads and applies correctly', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

    // Wait for CSS to load
    await registryPage.waitForLoadState('networkidle');

    // Check computed styles on key elements
    const header = registryPage.locator('h1').first();
    await expect(header).toHaveCSS('font-weight', '700'); // Assuming bold headers

    const mainContent = registryPage.locator('.workflow-content, main, .container').first();
    await expect(mainContent).toHaveCSS('display', /block|flex|grid/);

    // Take full page screenshot to verify styling
    await expect(registryPage).toHaveScreenshot('workflow-styling.png', { fullPage: true });
  });

  test('HTMX interactions work in workflow context', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

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
    await registryPage.goto('/workflow/tenant-signup');

    // Verify layout adapts to mobile
    await registryPage.expectWorkflowLayout();

    // Take mobile screenshot
    await expect(registryPage).toHaveScreenshot('tenant-signup-mobile.png');

    // Test that text is readable (not too small)
    const bodyText = registryPage.locator('body');
    await expect(bodyText).toHaveCSS('font-size', /1[4-9]px|[2-9][0-9]px/); // At least 14px
  });

  test('workflow navigation between steps works visually', async ({ registryPage }) => {
    // Start workflow
    await registryPage.goto('/workflow/tenant-signup');

    // Take screenshot of initial state
    await expect(registryPage).toHaveScreenshot('workflow-step-1.png');

    // Try to navigate to next step (if form is present)
    const nextButton = registryPage.locator('button[type="submit"], input[type="submit"], .next-step');
    if (await nextButton.count() > 0) {
      await nextButton.first().click();
      await registryPage.waitForLoadState('networkidle');

      // Take screenshot of next step
      await expect(registryPage).toHaveScreenshot('workflow-step-2.png');
    }
  });
});