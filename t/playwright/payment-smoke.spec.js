// ABOUTME: Playwright smoke test for the Stripe payment happy path in a tenant registration workflow.
// ABOUTME: Self-skips without STRIPE_SECRET_KEY; live run requires pk_test_ STRIPE_PUBLISHABLE_KEY.

const { test, expect } = require('./fixtures/base');
const { execSync, spawnSync } = require('child_process');

// ---------------------------------------------------------------------------
// Helper: run the Perl setup script and return parsed JSON.
// Mirrors the pattern in camp-registration.spec.js (execSync + JSON.parse).
// ---------------------------------------------------------------------------
function seedPaymentData(testDB) {
  const output = execSync(
    'carton exec perl t/playwright/setup_payment_test_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
      timeout: 150000,   // ready_account() polls Stripe for up to 90 s
    }
  ).trim();

  if (!output) {
    throw new Error('setup_payment_test_data.pl produced no output');
  }

  return JSON.parse(output);
}

// ---------------------------------------------------------------------------
// Helper: authenticate via magic link (mirrors camp-registration.spec.js).
// Navigates to /auth/magic/<token>, waits for the confirm button, clicks it,
// and waits for the redirect to complete.
// ---------------------------------------------------------------------------
async function loginWithMagicLink(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// ---------------------------------------------------------------------------
// Payment happy-path smoke test
// ---------------------------------------------------------------------------
test.describe('Payment happy path', () => {
  // Run serially -- the single test is inherently sequential.
  test.describe.configure({ mode: 'serial', timeout: 180000 });

  test('card payment charges Stripe and creates an enrollment in the tenant schema',
    async ({ registryPage, testDB }) => {
      // Self-skip when no test key is present.  A live pk_live_ key must never
      // reach the browser (see task safety note); the spec only runs with sk_test_.
      test.skip(
        !process.env.STRIPE_SECRET_KEY,
        'requires STRIPE_SECRET_KEY=sk_test_... and STRIPE_PUBLISHABLE_KEY=pk_test_...'
      );

      // -----------------------------------------------------------------------
      // 1. Provision test data (Connect-ready tenant, $150 session, parent/child,
      //    pre-seeded workflow run already at the session-selection step so
      //    next_step() returns payment).
      // -----------------------------------------------------------------------
      const data = seedPaymentData(testDB);
      const { tenant_slug, run_id, session_id, child_id, parent } = data;

      // -----------------------------------------------------------------------
      // 2. Log in via magic link (auth endpoint uses registry schema; token lives
      //    there).  Sets the session cookie so subsequent requests are authed.
      // -----------------------------------------------------------------------
      await loginWithMagicLink(registryPage, parent.token);

      // -----------------------------------------------------------------------
      // 3. Set the as-tenant cookie so subsequent requests route to the tenant
      //    schema.  The cookie is only honoured for authenticated sessions, so
      //    this must come after step 2.
      // -----------------------------------------------------------------------
      await registryPage.context().addCookies([{
        name:   'as-tenant',
        value:  tenant_slug,
        domain: '127.0.0.1',
        path:   '/',
      }]);

      // -----------------------------------------------------------------------
      // 4. Navigate directly to the pre-seeded run's payment step.
      //    The run already has user_id, children, session_selections, and
      //    enrollment_items populated, and latest_step_id = session-selection,
      //    so next_step() returns payment.
      // -----------------------------------------------------------------------
      await registryPage.goto(`/summer-camp-registration/${run_id}/payment`);
      await registryPage.waitForLoadState('networkidle');
      await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

      // Page should show the Registration Summary with the $150 total.
      await expect(registryPage.locator('body')).toContainText(/150/);

      // -----------------------------------------------------------------------
      // 5. Submit the agreeTerms form to trigger Stripe intent creation.
      //    The server responds inline (stay path) with the Stripe Payment Element.
      // -----------------------------------------------------------------------
      const agreeCheckbox = registryPage.locator('input[name="agreeTerms"]');
      await expect(agreeCheckbox).toBeVisible({ timeout: 10000 });
      await agreeCheckbox.check();

      // The submit button is enabled by JS only after the checkbox is checked.
      const submitBtn = registryPage.locator('#agreement-submit');
      await expect(submitBtn).toBeEnabled({ timeout: 5000 });
      await submitBtn.click();
      await registryPage.waitForLoadState('networkidle', { timeout: 20000 });

      await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

      // -----------------------------------------------------------------------
      // 6. Wait for the Stripe Payment Element iframe to mount inside #payment-element.
      //    Stripe.js loads asynchronously; allow up to 30 s.
      // -----------------------------------------------------------------------
      await registryPage.waitForSelector('#payment-element iframe', { timeout: 30000 });

      // -----------------------------------------------------------------------
      // 7. Fill the Stripe test card (4242... instant approval, no 3DS) inside
      //    the Stripe-hosted iframe.  Selectors target the standard placeholder
      //    text in the Stripe Payment Element card fields.
      // -----------------------------------------------------------------------
      const stripeFrame = registryPage.frameLocator('#payment-element iframe').first();

      await stripeFrame.locator('input[placeholder="1234 1234 1234 1234"]')
        .fill('4242424242424242', { timeout: 15000 });

      await stripeFrame.locator('input[placeholder="MM / YY"]').fill('12 / 34');
      await stripeFrame.locator('input[placeholder="CVC"]').fill('123');

      // ZIP is present on US cards in the Payment Element
      const zipInput = stripeFrame.locator('input[placeholder="ZIP"]');
      if (await zipInput.isVisible({ timeout: 3000 }).catch(() => false)) {
        await zipInput.fill('10001');
      }

      // -----------------------------------------------------------------------
      // 8. Submit the Stripe form.  stripe.confirmPayment() will process the card
      //    and redirect the browser to the return_url with payment_intent_id
      //    substituted, which triggers handle_payment_callback on the server and
      //    advances the workflow run to 'complete'.
      // -----------------------------------------------------------------------
      await registryPage.locator('#submit').click();

      // Wait for Stripe to process and redirect (or for the success/error UI).
      // Stripe redirects for card payments; allow up to 30 s for the round-trip.
      await registryPage.waitForLoadState('networkidle', { timeout: 30000 });

      // -----------------------------------------------------------------------
      // 9. Assert the workflow reached the completion page.
      // -----------------------------------------------------------------------
      await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
      await expect(registryPage.locator('body')).toContainText(
        /complete|confirmed|thank you|registration complete/i,
        { timeout: 15000 }
      );

      // -----------------------------------------------------------------------
      // 10. Assert via psql that an active enrollment row exists in the TENANT
      //     schema (mirrors the DB assertion pattern in tenant-signup.spec.js).
      // -----------------------------------------------------------------------
      const dbUrl = testDB.dbUrl;

      const enrollmentCheck = spawnSync('psql', [
        dbUrl, '-t', '-A',
        '-c',
        `SELECT COUNT(*) FROM "${tenant_slug}".enrollments`
        + ` WHERE family_member_id = '${child_id}'`
        + `   AND session_id = '${session_id}'`
        + `   AND status = 'active'`,
      ], { cwd: process.cwd(), encoding: 'utf8' });

      const enrollmentCount = parseInt(enrollmentCheck.stdout.trim(), 10);
      expect(
        enrollmentCount,
        'active enrollment exists in tenant schema after payment'
      ).toBeGreaterThan(0);
    }
  );
});
