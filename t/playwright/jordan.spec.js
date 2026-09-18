// ABOUTME: Jordan's user journey: running the business day from the admin dashboard.
// ABOUTME: Every assertion is about what the screen offers him, not what the route returns.
const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');
const { loginToken, loginWithToken, queryJson, daysFromNow } = require('./journey_helpers');

function seedWorld(testDB) {
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
  return JSON.parse(out);
}

test.describe.configure({ mode: 'serial', timeout: 180000 });

test.describe('Jordan: running the business day', () => {
  let data;

  test.beforeAll(async ({ testDB }) => { data = seedWorld(testDB); });

  // What he opens the dashboard to find out. Asserting the page renders proves
  // the route works; asserting his program is on it proves the dashboard does.
  test('the dashboard tells him what is happening today', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, loginToken(testDB, 'registry', data.admin_id));

    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    await registryPage.goto(`/admin/dashboard/todays_events?date=${daysFromNow(0)}`);
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('body')).toContainText(data.session_name);
  });

  // The queue has to fill and empty. Only checking that it fills proves half a
  // feature: a list that never empties is as useless as one that never fills.
  test('a drop request reaches his queue and leaves it once approved', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, loginToken(testDB, 'registry', data.admin_id));

    // Raised by the parent, out of band -- this is Jordan's journey, not hers.
    execSync(
      `carton exec perl -Ilib -It/lib -MRegistry::DAO -MRegistry::DAO::Enrollment -e '
        my $dao = Registry::DAO->new(url => $ENV{DB_URL});
        my $e = Registry::DAO::Enrollment->find($dao->db, { session_id => "${data.session_id}" });
        $e->request_drop($dao->db, { id => "${data.parent_id}", role => "parent" }, "Family moving", 0);
      '`,
      { cwd: process.cwd(), env: { ...process.env, DB_URL: testDB.dbUrl }, stdio: ['ignore', 'pipe', 'pipe'] }
    );

    await registryPage.goto('/admin/dashboard/pending_drop_requests');
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('body'), 'the queue fills')
      .toContainText(data.child_name);

    // Approved out of band, as an admin action the queue is the view onto.
    // Checking only that it fills proves half a feature: a queue that never
    // empties is as useless as one that never fills.
    execSync(
      `carton exec perl -Ilib -It/lib -MRegistry::DAO -MRegistry::DAO::DropRequest -e '
        my $dao = Registry::DAO->new(url => $ENV{DB_URL});
        my ($r) = Registry::DAO::DropRequest->find($dao->db, { status => "pending" });
        $r->approve($dao->db, { id => "${data.admin_id}", role => "admin" }, "Approved");
      '`,
      { cwd: process.cwd(), env: { ...process.env, DB_URL: testDB.dbUrl }, stdio: ['ignore', 'pipe', 'pipe'] }
    );

    await registryPage.goto('/admin/dashboard/pending_drop_requests');
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('body'), 'and empties once approved')
      .not.toContainText(data.child_name);
  });

  // Publishing is his only action that changes what a parent can see, and the
  // control is a real button on the program overview. Pressing it is the point:
  // a POST to the route would prove the endpoint works while saying nothing
  // about whether Jordan can reach it.
  //
  // The row is read back rather than the page re-read, because the form is
  // hx-swap="none" -- after the click the screen looks identical, which is
  // #181.
  test('he can take a session off sale and put it back', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, loginToken(testDB, 'registry', data.admin_id));

    const statusOf = () => queryJson(
      testDB, 'registry',
      'SELECT status FROM sessions WHERE id = ?', data.session_id
    )[0].status;

    expect(statusOf(), 'starts on sale').toBe('published');

    const sessionRow = registryPage.locator(`li[data-session-id="${data.session_id}"]`);

    // The dashboard he actually opens. /admin/dashboard is the admin-dashboard
    // WORKFLOW, whose overview HTMX-loads the program section and renders
    // admin-dashboard/program_overview -- the one template tree there is.
    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');
    await expect(sessionRow, 'his session is listed').toBeVisible({ timeout: 15000 });

    const unpublish = sessionRow.getByRole('button', { name: /unpublish/i });
    await expect(unpublish, 'and offers a way to take it off sale').toBeVisible();
    await unpublish.click();
    await expect.poll(statusOf, { timeout: 10000 }).toBe('draft');

    // Reloaded, because hx-swap="none" leaves the old button in place (#181).
    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');

    // Putting it back is refused, and rightly: the session costs $300 and this
    // organisation has no Connect account, so it cannot be paid. That is the
    // gate from #366 seen from the owner's chair rather than the parent's --
    // the whole point of moving it to publish time was that Jordan finds out
    // here instead of a parent finding out at checkout.
    const publish = sessionRow.getByRole('button', { name: /^publish/i });
    await expect(publish, 'the screen offers to put it back').toBeVisible({ timeout: 10000 });
    await publish.click();

    // Nothing moves. Asserted by holding the poll for its full timeout rather
    // than reading once, so a slow write cannot pass for a refusal.
    await expect.poll(statusOf, { timeout: 5000 }).toBe('draft');
    expect(statusOf(), 'a paid session stays off sale until it can be paid for').toBe('draft');
  });
});
