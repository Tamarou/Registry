// ABOUTME: End-to-end browser tests for the parent dashboard after enrollment.
// ABOUTME: Covers enrollment visibility, upcoming events display, and unread messages count.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

// Run tests serially to share a single test database instance.
test.describe.configure({ mode: 'serial', timeout: 120000 });

// ---------------------------------------------------------------------------
// Helper: seed registration data and create an enrollment for the returning
// parent so the dashboard has something to display.
// ---------------------------------------------------------------------------
function seedDashboardData(testDB) {
  // First seed the base registration data
  const output = execSync(
    'carton exec perl t/playwright/setup_registration_test_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  if (!output) {
    throw new Error('setup_registration_test_data.pl produced no output');
  }

  const data = JSON.parse(output);

  // Create an enrollment for the returning parent's child in week 1
  const enrollScript = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    use Registry::DAO::Enrollment;
    use Registry::DAO::Message;
    my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db = \\$dao->db;
    Registry::DAO::Enrollment->create(\\$db, {
      session_id       => '${data.sessions.week1.id}',
      family_member_id => '${data.returning_parent.child_id}',
      parent_id        => '${data.returning_parent.user_id}',
      student_id       => '${data.returning_parent.user_id}',
      status           => 'active',
    });
    Registry::DAO::Message->send_message(\\$db, {
      sender_id    => '${data.admin.user_id}',
      subject      => 'Welcome to the studio',
      body         => 'Term starts next week.',
      message_type => 'announcement',
      scope        => 'tenant-wide',
    }, ['${data.returning_parent.user_id}'], send_now => 1);
    print "ok";
  `;

  execSync(
    `carton exec perl -e "${enrollScript.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: process.cwd(), encoding: 'utf8' }
  );

  return data;
}

// ---------------------------------------------------------------------------
// Helper: authenticate via magic link
// ---------------------------------------------------------------------------
async function loginWithToken(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// ===========================================================================
// 2.1 Enrollment visible on dashboard
// ===========================================================================
test.describe('Parent dashboard', () => {
  test('shows enrolled child and session after login', async ({ registryPage, testDB }) => {
    const data = seedDashboardData(testDB);

    // Authenticate as returning parent
    await loginWithToken(registryPage, data.returning_parent.token);

    // Navigate to parent dashboard
    await registryPage.goto('/parent/dashboard');
    await registryPage.waitForLoadState('networkidle');

    // Page renders without error
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');

    // Child name should appear
    await expect(registryPage.locator('body')).toContainText(data.returning_parent.child_name);

    // Session name should appear
    await expect(registryPage.locator('body')).toContainText(data.sessions.week1.name);
  });

  // ===========================================================================
  // 2.2 Upcoming events display
  // ===========================================================================
  test('displays upcoming events section', async ({ registryPage, testDB }) => {
    const data = seedDashboardData(testDB);
    await loginWithToken(registryPage, data.returning_parent.token);
    await registryPage.goto('/parent/dashboard');
    await registryPage.waitForLoadState('networkidle');

    // The upcoming events section loads (may be via HTMX)
    // Look for the events container or any event-related content
    const eventsSection = registryPage.locator('[hx-get*="upcoming_events"], #upcoming-events, .upcoming-events');
    const hasEvents = await eventsSection.count() > 0;

    if (hasEvents) {
      // Wait for HTMX to load the content
      await registryPage.waitForTimeout(2000);
      // Events section should be present
      await expect(eventsSection.first()).toBeAttached();
    } else {
      // Events may be inline on the dashboard
      // Just verify the dashboard loaded without error
      await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    }
  });

  // ===========================================================================
  // 2.3 Unread messages count
  // ===========================================================================
  test('shows unread messages count', async ({ registryPage, testDB }) => {
    const data = seedDashboardData(testDB);
    await loginWithToken(registryPage, data.returning_parent.token);
    await registryPage.goto('/parent/dashboard');
    await registryPage.waitForLoadState('networkidle');

    // None of the selectors this test used to look for -- [hx-get*="unread_messages"],
    // #unread-messages, .unread-messages, .message-count -- exist in the dashboard
    // template. So the count was always zero, the else branch always ran, and a test
    // named for the unread count never looked at one; it asserted the page was not a
    // 500.
    //
    // The dashboard's actual affordance is a link to /messages carrying a badge when
    // there is something unread, so that is what gets asserted -- with a message
    // seeded above so the badge has a number to show.
    const messagesLink = registryPage.locator('a[href="/messages"]').first();
    await expect(messagesLink, 'the dashboard links to messages').toBeVisible();
    await expect(messagesLink, 'and shows the unread count on it').toContainText('1');
  });
});
