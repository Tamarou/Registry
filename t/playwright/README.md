# Playwright Tests for Registry

This directory contains automated browser tests for Registry using Playwright.

## What These Tests Do

These tests complement Registry's existing comprehensive test suite by adding:

- **Visual regression testing** - Catch layout and styling issues
- **UTF-8/emoji rendering validation** - Ensure proper encoding across browsers
- **HTMX interaction testing** - Verify dynamic behavior works correctly
- **Cross-browser compatibility** - Test in Chrome, Firefox, Safari
- **Mobile responsiveness** - Ensure mobile experience is solid
- **Component integration** - Test web components within workflow contexts

## Test Files

- `smoke-test.spec.js` - Basic connectivity and setup verification
- `workflow-layout-visual.spec.js` - Comprehensive workflow layout testing (would have caught Issue #60)
- `all-workflows-visual.spec.js` - Cross-workflow consistency testing
- `component-integration.spec.js` - Web component and HTMX interaction testing
- `fixtures/base.js` - Shared test utilities and database setup

## Running Tests

Playwright tests are **optional** and will only run if Playwright is installed:

```bash
# Run all Playwright tests (skips if Playwright not installed)
make test-playwright

# Run all tests (Perl + Playwright if available)
make test-all

# Install Playwright first if needed
npm install && npx playwright install

# Run with UI (for debugging)
npm run test:playwright:ui

# Run specific test file
npx playwright test workflow-layout-visual.spec.js

# Run with headed browser (see what's happening)
npm run test:playwright:headed
```

**Note**: If Playwright isn't installed, `make test-playwright` will show a helpful message and continue without failing.

## Test Requirements

- **Database**: Tests create isolated test databases automatically
- **Server**: Playwright config starts Registry server automatically
- **Dependencies**: Run `npm install` and `npx playwright install` first

## CI Integration

These tests run automatically on:
- Every push to main/develop branches
- Every pull request
- Results and screenshots are uploaded as GitHub Actions artifacts

## Following Registry Patterns

These tests follow Registry's established patterns:
- **100% pass rate required** - No failing tests allowed
- **TDD approach** - Tests define expected behavior first
- **Isolated test data** - Each test gets fresh database
- **Comprehensive coverage** - Visual, functional, and integration testing
- **Real data usage** - No mocks, tests use actual Registry workflows

## Issue #60 Prevention

The workflow layout tests specifically prevent regressions like GitHub Issue #60 by:
- Verifying complete HTML structure (html, head, body tags)
- Checking CSS and JavaScript inclusion
- Validating UTF-8 encoding and emoji rendering
- Testing layout consistency across all workflow types
- Cross-browser compatibility verification

These tests would have immediately caught the missing layout wrapper issue that caused broken styling and emoji rendering.