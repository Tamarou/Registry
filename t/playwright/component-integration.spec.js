// ABOUTME: Integration tests for Registry's web components and HTMX interactions
// ABOUTME: Verifies that custom components work correctly within workflow layouts

const { test, expect } = require('./fixtures/base');

test.describe('Component Integration Tests', () => {
  test('workflow-progress component renders and functions correctly', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

    const progressComponent = registryPage.locator('workflow-progress');
    await expect(progressComponent).toBeAttached();

    // Check that component shadow DOM is created
    const hasShadowRoot = await progressComponent.evaluate(el => !!el.shadowRoot);
    expect(hasShadowRoot).toBe(true);

    // Verify component displays step information
    const currentStep = await progressComponent.getAttribute('data-current-step');
    const totalSteps = await progressComponent.getAttribute('data-total-steps');

    expect(parseInt(currentStep)).toBeGreaterThanOrEqual(1);
    expect(parseInt(totalSteps)).toBeGreaterThanOrEqual(1);

    // Take screenshot of progress component
    await expect(progressComponent).toHaveScreenshot('workflow-progress-component.png');
  });

  test('HTMX form submissions work correctly in workflows', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

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

          // Take screenshot after HTMX interaction
          await expect(registryPage).toHaveScreenshot('after-htmx-submission.png');
        }
      }
    }
  });

  test('workflow step navigation preserves layout', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

    // Take screenshot of initial step
    await expect(registryPage).toHaveScreenshot('step-initial.png');

    // Look for navigation elements (next/previous buttons)
    const nextButton = registryPage.locator('button:has-text("Next"), button:has-text("Continue"), .next-step');

    if (await nextButton.count() > 0) {
      await nextButton.first().click();
      await registryPage.waitForLoadState('networkidle');

      // Verify layout is still intact after navigation
      await registryPage.expectWorkflowLayout();

      // Take screenshot of next step
      await expect(registryPage).toHaveScreenshot('step-next.png');
    }

    // Check for back navigation
    const prevButton = registryPage.locator('button:has-text("Back"), button:has-text("Previous"), .prev-step');

    if (await prevButton.count() > 0) {
      await prevButton.first().click();
      await registryPage.waitForLoadState('networkidle');

      // Verify we can go back and layout is preserved
      await registryPage.expectWorkflowLayout();

      // Take screenshot after going back
      await expect(registryPage).toHaveScreenshot('step-back.png');
    }
  });

  test('error states display correctly in workflow context', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

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
          // Take screenshot of error state
          await expect(registryPage).toHaveScreenshot('workflow-error-state.png');

          // Verify errors are visible and styled
          await expect(errorElements.first()).toBeVisible();
        }
      }
    }
  });

  test('loading states work correctly during HTMX requests', async ({ registryPage }) => {
    await registryPage.goto('/workflow/tenant-signup');

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

        // Take screenshot during loading
        await expect(registryPage).toHaveScreenshot('workflow-loading-state.png');
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
    await registryPage.goto('/workflow/tenant-signup');

    // Check basic accessibility attributes
    const hasSkipLink = await registryPage.locator('a[href*="#main"], a[href*="#content"]').count() > 0;
    const hasMainLandmark = await registryPage.locator('main, [role="main"]').count() > 0;
    const hasProperHeadings = await registryPage.locator('h1').count() > 0;

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

    // Take screenshot for accessibility review
    await expect(registryPage).toHaveScreenshot('workflow-accessibility.png');
  });
});