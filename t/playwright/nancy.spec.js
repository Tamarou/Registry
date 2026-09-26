// ABOUTME: Nancy's user journey: find a program, register her child, see the enrolment afterwards.
// ABOUTME: Every step asserts the screen offered the control before using it.
const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');
const { loginToken, loginWithToken, queryJson, daysFromNow } = require('./journey_helpers');

// Nancy starts from a world a tenant has already built. She does not walk
// Morgan's screens to get here -- that is Morgan's journey, and requiring it
// would make this file unreadable without his in scope.
function seedWorld(testDB) {
  // stderr is carried into the failure. A seed that dies silently costs a run
  // to diagnose, which is the same complaint as #322 in a different place.
  let out;
  try {
    out = execSync('carton exec perl t/playwright/setup_registration_test_data.pl', {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
      timeout: 120000,
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (e) {
    throw new Error(`seed failed: ${e.stderr || e.stdout || e.message}`);
  }
  if (!out) throw new Error('setup_registration_test_data.pl produced no output');
  return JSON.parse(out);
}

test.describe.configure({ mode: 'serial', timeout: 180000 });

test.describe('Nancy: finding a program and enrolling her child', () => {
  let data;

  test.beforeAll(async ({ testDB }) => { data = seedWorld(testDB); });

  // Discovery. A program nobody can find is not for sale, so this asserts the
  // screen renders what Nancy needs to decide -- the program, and a session
  // with dates -- and then that it offers her a way in.
  test('the storefront shows a program Nancy can register for', async ({ registryPage }) => {
    // The default host. This seed creates a tenant row but no tenant schema --
    // its data lives in registry, which is where every other spec built on it
    // reaches the program too.
    await registryPage.goto('/tenant-storefront');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(data.program_name);

    // The storefront presents a session by its dates, not its internal name,
    // and the dates are what a parent decides on. Asserting the derived value
    // also proves it reached the screen: pinned to June, as this seed was,
    // end_date >= CURRENT_DATE empties the page entirely.
    await expect(registryPage.locator('body')).toContainText(daysFromNow(14));

    // The ability, not just the information -- and the control belonging to
    // THIS program. A bare .first() matched whatever button the page happened
    // to render first, which once other specs had seeded their own data was a
    // different journey entirely.
    // This run's program, not any program sharing the name. Several specs use
    // this seed, so by the time Nancy runs there are several of them -- the
    // name carries a timestamp precisely so they can be told apart.
    const card = registryPage.locator('article').filter({ hasText: data.program_name });
    await expect(card, 'the program has a card of its own').toBeVisible({ timeout: 10000 });
    await expect(card.getByRole('button', { name: /register/i })).toBeVisible();

    // She is deciding here, so the card has to say what it costs and whether
    // there is room. ProgramListing computed both and the template dropped
    // them, so she chose on a name and a pair of dates alone.
    await expect(card, 'the card says what it costs')
      .toContainText('$300');
    await expect(card, 'and whether there is still room')
      .toContainText(/\b\d+ (?:spot|place)s? left\b/i);
  });

  // Every registration crosses the same screens before the session choice, and
  // two journeys through them drift apart the moment one is edited. The
  // assertions live here because they are true of both: entering from the
  // storefront is what carries the program into the run, and her existing child
  // has to be offered by name whatever she goes on to choose.
  async function walkToSessionSelection(page) {
    // Entered from the storefront, by pressing Register on the program --
    // which is what carries the program into the run. Navigating straight to
    // /summer-camp-registration reaches session-selection with no program_id,
    // and that screen then offers nothing with its Continue button disabled.
    await page.goto('/tenant-storefront');
    await page.waitForLoadState('networkidle');
    await page.locator('article')
      .filter({ hasText: data.program_name })
      .getByRole('button', { name: /register/i })
      .click();
    await page.waitForLoadState('networkidle');
    await expect(page.locator('body')).not.toContainText('Internal Server Error');

    // Landing: the way in has to be a control she can press.
    const begin = page.locator('form button[type="submit"], form input[type="submit"]').first();
    if (await begin.count()) {
      await begin.click();
      await page.waitForLoadState('networkidle');
    }

    // Account check, if the workflow stops here at all. Entering from the
    // storefront while signed in, it does not -- she goes straight to choosing
    // children, which is the right behaviour and the reason this is a
    // condition rather than a requirement. When the screen does appear it must
    // offer continuing rather than making her create a second account.
    const continueForm = page.locator(
      'form:has(input[name="action"][value="continue_logged_in"])'
    );
    if (await continueForm.count()) {
      await continueForm.locator('button[type="submit"]').click();
      await page.waitForLoadState('networkidle');
    }

    // Select children: her existing child must be offered by name.
    await expect(page.locator('body')).toContainText(data.returning_parent.child_name);
    const childControl = page.locator(`input[name^="child_"]`).first();
    await expect(childControl).toBeVisible({ timeout: 10000 });
    await childControl.check();

    const nextFromChildren = page.locator('form button[type="submit"]').first();
    await expect(nextFromChildren).toBeVisible();
    await nextFromChildren.click();
    await page.waitForLoadState('networkidle');

    // Camper info: whatever this screen asks for, it has to be fillable. Each
    // field is optional in the sense that the screen decides which it shows;
    // none of them may be missing when the screen does show it.
    for (const [selector, value] of [
      ['input[name="childName"]', data.returning_parent.child_name],
      ['input[name="childAge"]', '8'],
      ['input[name="parentName"]', 'Nancy Returning'],
      ['input[name="parentEmail"]', data.returning_parent.email],
      ['input[name="parentPhone"]', '555-0101'],
      ['input[name="emergencyContact"]', 'Emergency Contact'],
      ['input[name="emergencyPhone"]', '555-0100'],
    ]) {
      const field = page.locator(selector);
      if (await field.count()) await field.first().fill(value);
    }

    // Grade is a select, and the screen requires one.
    const grade = page.locator('select[name="gradeLevel"]');
    if (await grade.count()) await grade.first().selectOption({ index: 1 });
    await page.locator('button[type="submit"]').first().click();
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveURL(/session-selection/, { timeout: 10000 });
  }

  // The registration screens themselves, as a signed-in returning parent --
  // the shortest path that still crosses every screen that matters.
  test('Nancy registers her child through the screens', async ({ registryPage }) => {
    await loginWithToken(registryPage, data.returning_parent.token);
    await walkToSessionSelection(registryPage);

    // Session selection: the session Nancy is buying has to be offered as a
    // control naming it, not merely mentioned on the page.
    const sessionControl = registryPage.locator(
      `input[value="${data.sessions.week1.id}"]`
    ).first();
    await expect(sessionControl).toBeVisible({ timeout: 10000 });
    await sessionControl.check();

    await registryPage.locator('button[type="submit"]').first().click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Payment: the total has to be on the screen before she agrees to it.
    await expect(registryPage.locator('body')).toContainText('300');
    const agree = registryPage.locator('input[name="agreeTerms"]');
    await expect(agree).toBeVisible({ timeout: 10000 });
    await agree.check();
    await registryPage.locator('#agreement-submit, button[type="submit"]').first().click();
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/Registration Complete/i, { timeout: 15000 });

    // Completing is not the same as being told what you completed. This page
    // used to read run-data keys no step writes, so it greeted every parent
    // with "Camper: N/A" and an empty session list after they had paid.
    const details = registryPage.locator('.registration-details');
    await expect(details, 'the confirmation names the child she enrolled')
      .toContainText(data.returning_parent.child_name);
    await expect(details, 'and the session she bought')
      .toContainText(data.sessions.week1.name);
    await expect(details, 'with the dates she saw when she chose it')
      .toContainText(data.sessions.week1.start);
    await expect(details, 'and not a placeholder where the answer should be')
      .not.toContainText('N/A');
  });

  // The week Nancy wanted is full. She should be able to wait for it rather
  // than be told to pick a different one -- the storefront invites her to join
  // the waitlist, and following that invitation has to lead somewhere. The seed
  // fills Week 3 to its capacity of two, so this is the real screen.
  test('Nancy joins the waitlist for a session that is full', async ({ registryPage, testDB }) => {
    await loginWithToken(
      registryPage,
      loginToken(testDB, 'registry', data.returning_parent.user_id)
    );
    await walkToSessionSelection(registryPage);

    // Offered, and honest about what choosing it means. A full session that is
    // simply absent is the bug this journey exists for: the invitation led to a
    // screen with nothing on it to choose.
    const fullControl = registryPage.locator(
      `input[value="${data.sessions.week3_full.id}"]`
    ).first();
    await expect(fullControl, 'the full session is still offered')
      .toBeVisible({ timeout: 10000 });

    const fullLabel = registryPage.locator('label').filter({ has: fullControl });
    await expect(fullLabel, 'and says that choosing it joins the waitlist')
      .toContainText(/waitlist/i);

    await fullControl.check();
    await registryPage.locator('button[type="submit"]').first().click();
    await registryPage.waitForLoadState('networkidle');

    // Not refused. The old behaviour was an error telling her to choose a
    // session with room, which is the one thing she had already decided against.
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).not.toContainText(/Please select a different session/i);

    // Nothing is owed for a place that does not exist yet.
    await expect(registryPage.locator('body'), 'there is nothing to pay for a waitlist place')
      .not.toContainText('$300');
    const agree = registryPage.locator('input[name="agreeTerms"]');
    await expect(agree).toBeVisible({ timeout: 10000 });
    await agree.check();
    await registryPage.locator('#agreement-submit, button[type="submit"]').first().click();
    await registryPage.waitForLoadState('networkidle');

    // The confirmation has to say which of the two things happened. Greeting a
    // waiting child as enrolled claims a seat that is not there.
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/waitlist/i, { timeout: 15000 });

    const details = registryPage.locator('.registration-details');
    await expect(details, 'the child is named').toContainText(data.returning_parent.child_name);
    await expect(details, 'and marked as waiting rather than enrolled')
      .toContainText(/Waitlisted/i);

    // Asserted off the row, not the page: a confirmation that says "waitlist"
    // while writing nothing is exactly the failure this is for.
    const rows = queryJson(testDB, 'registry',
      'SELECT status FROM waitlist WHERE session_id = ? AND student_id = ?',
      data.sessions.week3_full.id, data.returning_parent.child_id);
    expect(rows.length, 'a waitlist entry exists for her child').toBe(1);
    expect(rows[0].status).toBe('waiting');
  });

  // The job is not done when the form is submitted. It is done when Nancy can
  // see what she bought.
  test('her dashboard shows the child she enrolled', async ({ registryPage, testDB }) => {
    // A fresh token: each test gets its own browser context, and a magic link
    // is single-use. Minting one here also keeps this test independent of the
    // one before it.
    await loginWithToken(
      registryPage,
      loginToken(testDB, 'registry', data.returning_parent.user_id)
    );

    await registryPage.goto('/parent/dashboard');
    await registryPage.waitForLoadState('networkidle');

    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(data.returning_parent.child_name);
  });
});
