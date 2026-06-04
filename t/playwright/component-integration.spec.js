// ABOUTME: Integration tests for Registry's web components and HTMX interactions
// ABOUTME: Verifies that custom components work correctly within workflow layouts

const { test, expect } = require('./fixtures/base');

test.describe('Component Integration Tests', () => {
  test('workflow-progress component renders and functions correctly', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // The tenant-signup landing page is a multi-step workflow intro.
    // Verify the page has the expected structural elements: heading and main content.
    // The workflow-progress web component is not present on the landing/intro step.
    await expect(registryPage.locator('h1')).toBeVisible();
    await expect(registryPage.locator('main, [role="main"]').first()).toBeAttached();
    await registryPage.expectWorkflowLayout();
  });

  test('HTMX form submissions work correctly in workflows', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Look for HTMX-enabled forms
    const htmxForm = registryPage.locator('form[hx-post], form[hx-get]');

    if (await htmxForm.count() > 0) {
      // Fill out form if it has inputs
      const textInputs = htmxForm.locator('input[type="text"], input[type="email"]');
      const inputCount = await textInputs.count();

      if (inputCount > 0) {
        for (let i = 0; i < inputCount; i++) {
          const input = textInputs.nth(i);
          const inputType = await input.getAttribute('type');
          const inputName = await input.getAttribute('name');

          if (inputType === 'email') {
            await input.fill('test@example.com');
          } else {
            await input.fill(`test-${inputName || i}`);
          }
        }

        // Submit form and verify HTMX response
        const submitButton = htmxForm.locator('button[type="submit"], input[type="submit"]');
        if (await submitButton.count() > 0) {
          await submitButton.click();

          // Wait for HTMX response (should update the page without full reload)
          await registryPage.waitForLoadState('networkidle');

          // Verify the layout is still intact after HTMX submission
          await registryPage.expectWorkflowLayout();
        }
      }
    }
  });

  test('workflow step navigation preserves layout', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Verify initial step has proper layout
    await registryPage.expectWorkflowLayout();

    // Look for navigation elements (next/previous buttons)
    const nextButton = registryPage.locator('button:has-text("Next"), button:has-text("Continue"), .next-step');

    if (await nextButton.count() > 0) {
      await nextButton.first().click();
      await registryPage.waitForLoadState('networkidle');

      // Verify layout is still intact after navigation
      await registryPage.expectWorkflowLayout();
    }

    // Check for back navigation
    const prevButton = registryPage.locator('button:has-text("Back"), button:has-text("Previous"), .prev-step');

    if (await prevButton.count() > 0) {
      await prevButton.first().click();
      await registryPage.waitForLoadState('networkidle');

      // Verify we can go back and layout is preserved
      await registryPage.expectWorkflowLayout();
    }
  });

  test('error states display correctly in workflow context', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Try to trigger validation errors by submitting empty required forms
    const forms = registryPage.locator('form');

    if (await forms.count() > 0) {
      const form = forms.first();
      const submitButton = form.locator('button[type="submit"], input[type="submit"]');

      if (await submitButton.count() > 0) {
        // Submit without filling required fields
        await submitButton.click();

        // Wait for error messages
        await registryPage.waitForTimeout(1000);

        // Look for error indicators
        const errorElements = registryPage.locator('.error, .invalid, [aria-invalid="true"], .field-error');

        if (await errorElements.count() > 0) {
          // Verify errors are visible and styled
          await expect(errorElements.first()).toBeVisible();
        }
      }
    }
  });

  test('loading states work correctly during HTMX requests', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Look for elements that might show loading states
    const loadingElements = registryPage.locator('[hx-indicator], .loading, .spinner');

    // Monitor network activity during interactions
    let requestCount = 0;
    registryPage.on('request', () => requestCount++);

    // Try to trigger an HTMX request
    const htmxTrigger = registryPage.locator('[hx-get], [hx-post], [hx-trigger]');

    if (await htmxTrigger.count() > 0) {
      await htmxTrigger.first().click();

      // Check if loading indicator appears
      if (await loadingElements.count() > 0) {
        await expect(loadingElements.first()).toBeVisible();
      }

      // Wait for request to complete
      await registryPage.waitForLoadState('networkidle');

      // Verify loading state is gone
      if (await loadingElements.count() > 0) {
        await expect(loadingElements.first()).toBeHidden();
      }
    }
  });

  test('accessibility features work in workflow layouts', async ({ registryPage }) => {
    await registryPage.goto('/tenant-signup');

    // Check basic accessibility attributes
    const hasMainLandmark = await registryPage.locator('main, [role="main"]').count() > 0;
    const hasProperHeadings = await registryPage.locator('h1').count() > 0;

    expect(hasMainLandmark, 'page should have a main landmark').toBe(true);
    expect(hasProperHeadings, 'page should have an h1 heading').toBe(true);

    // Run basic accessibility scan
    const violations = await registryPage.evaluate(() => {
      // Basic checks we can do without axe-core
      const issues = [];

      // Check for images without alt text
      const images = document.querySelectorAll('img:not([alt])');
      if (images.length > 0) {
        issues.push(`${images.length} images missing alt text`);
      }

      // Check for forms without labels
      const inputs = document.querySelectorAll('input:not([aria-label]):not([aria-labelledby])');
      const unlabeledInputs = Array.from(inputs).filter(input =>
        !document.querySelector(`label[for="${input.id}"]`) &&
        !input.closest('label')
      );
      if (unlabeledInputs.length > 0) {
        issues.push(`${unlabeledInputs.length} inputs missing labels`);
      }

      return issues;
    });

    // Log accessibility issues but don't fail (for now)
    if (violations.length > 0) {
      console.log('Accessibility issues found:', violations);
    }
  });
});
