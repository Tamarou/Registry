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
      // The Connect account this creates has to outlive the seed process --
      // the browser drives a payment against the tenant it belongs to. Without
      // this the helper's END block deletes it on exit and Stripe answers the
      // payment intent with "the account has been deleted".
      env: {
        ...process.env,
        DB_URL: testDB.dbUrl,
        REGISTRY_STRIPE_KEEP_ACCOUNTS: '1',
      },
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
// The account the seed disowned, deleted once the run is done with it.
let seededConnectAccount = null;

test.describe('Payment happy path', () => {
  test.afterAll(async () => {
    if (!seededConnectAccount || !process.env.STRIPE_SECRET_KEY) return;

    const res = await fetch(
      `https://api.stripe.com/v1/accounts/${seededConnectAccount}`,
      { method: 'DELETE',
        headers: { Authorization: `Bearer ${process.env.STRIPE_SECRET_KEY}` } }
    );
    console.log(`# Connect account ${seededConnectAccount} delete: ${res.status}`);
  });

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
      seededConnectAccount = data.connect_account;

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
      //    the Stripe-hosted iframe.  Selectors target the input names the
      //    Payment Element gives its card fields.
      // -----------------------------------------------------------------------
      // Target the fields by name. The placeholders are display copy: the
      // postal code's is "12345", not "ZIP", so the old selector matched
      // nothing, the field was left empty, and Stripe refused the confirm with
      // "Your ZIP code is invalid." Names are part of the Element's API.
      const stripeFrame = registryPage.frameLocator('#payment-element iframe').first();

      await stripeFrame.locator('input[name="number"]')
        .fill('4242424242424242', { timeout: 15000 });
      await stripeFrame.locator('input[name="expiry"]').fill('12 / 34');
      await stripeFrame.locator('input[name="cvc"]').fill('123');

      // The postal code renders once the card number is recognised, so it needs
      // a wait rather than a visibility probe. Required, not optional: treating
      // it as optional is what let an unfilled field reach Stripe unnoticed.
      const postalCode = stripeFrame.locator('input[name="postalCode"]');
      await expect(postalCode).toBeVisible({ timeout: 15000 });
      await postalCode.fill('10001');
      await expect(postalCode).toHaveValue('10001');

      // -----------------------------------------------------------------------
      // 8. Submit the Stripe form.  stripe.confirmPayment() processes the card and
      //    redirects the browser to the return_url, onto which Stripe appends
      //    payment_intent.  The GET handler hands that intent to the payment step,
      //    which triggers handle_payment_callback and advances the run to
      //    'complete'.
      // -----------------------------------------------------------------------
      await registryPage.locator('#submit').click();

      // The confirm ends in one of two places: the completion page, or the
      // payment page with #payment-error shown. Wait for whichever arrives.
      // networkidle cannot tell them apart and timed out on its own when the
      // card was refused, since a refusal never navigates.
      await expect(
        registryPage.locator('#payment-error:visible, body:has-text("Registration Complete")')
      ).toBeVisible({ timeout: 30000 });

      // -----------------------------------------------------------------------
      // 9. Assert the workflow reached the completion page.
      // -----------------------------------------------------------------------
      await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

      // Stripe reports a refused card on the payment page itself. Say so here
      // rather than letting it surface as a missing enrollment twenty lines on.
      // Asserted on the element's visibility: the error box is always in the
      // DOM, so body text contains "Payment Error" whether or not it is shown.
      await expect(registryPage.locator('#payment-error')).toBeHidden();

      // Name the completion page. The old pattern allowed a bare "complete",
      // which the payment page's own copy contains -- "redirected to a secure
      // payment form to complete your registration" -- so the assertion passed
      // on the page it was meant to prove the parent had left.
      await expect(registryPage.locator('body')).toContainText(
        /Registration Complete/i,
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
