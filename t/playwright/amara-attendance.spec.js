// ABOUTME: End-to-end browser test for Amara's teacher attendance journey.
// ABOUTME: Tests dashboard access, event viewing, and attendance marking via Web Components.

const { test, expect } = require('./fixtures/base');
const { queryJson } = require('./journey_helpers');
const { execSync } = require('child_process');

test.describe.configure({ mode: 'serial', timeout: 120000 });

function seedTeacherData(testDB) {
  const output = execSync(
    'carton exec perl t/playwright/setup_teacher_test_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  if (!output) {
    throw new Error('setup_teacher_test_data.pl produced no output');
  }
  return JSON.parse(output);
}

// Mint a fresh single-use magic link token for the given user.
// Magic link tokens are single-use; call this right before each loginWithToken.
// Perl sigils must be escaped with \\$ so the shell does not consume them.
function freshToken(testDB, userId) {
  const script = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    use Registry::DAO::MagicLinkToken;
    my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db  = \\$dao->db;
    my (undef, \\$pt) = Registry::DAO::MagicLinkToken->generate(\\$db, {
        user_id    => '${userId}',
        purpose    => 'login',
        expires_in => 24,
    });
    print \\$pt;
  `;

  const plaintext = execSync(
    `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: process.cwd(), encoding: 'utf8' }
  ).trim();

  if (!plaintext) {
    throw new Error('freshToken: empty output from Perl helper');
  }
  return plaintext;
}

async function loginWithToken(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// ===========================================================================
// Amara's Teacher Attendance Journey
// ===========================================================================
test.describe('Amara teacher attendance journey', () => {
  let testData;

  test.beforeAll(async ({ testDB }) => {
    testData = seedTeacherData(testDB);
  });

  test('Amara logs in via magic link', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.teacher_id));
    await expect(registryPage).toHaveURL(/\//);
  });

  test('Amara sees the teacher dashboard', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.teacher_id));
    await registryPage.goto('/teacher/');

    // Dashboard renders with navigation and teacher-specific content
    await expect(registryPage.locator('nav.dashboard-nav')).toBeVisible();
    await expect(registryPage).toHaveTitle(/Teacher Dashboard/);
  });

  test('Amara sees navigation with staff links', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.teacher_id));
    await registryPage.goto('/teacher/');

    const nav = registryPage.locator('nav.dashboard-nav');
    await expect(nav.locator('a[href="/teacher/"]')).toBeVisible();
    await expect(nav.locator('a[href="/admin/dashboard"]')).toBeVisible();

    // Staff should NOT see admin-only domains link
    await expect(nav.locator('a[href="/admin/domains"]')).toHaveCount(0);
  });

  test('Amara can view attendance page for her event', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.teacher_id));
    await registryPage.goto(`/teacher/attendance/${testData.event_id}`);

    await expect(registryPage).toHaveTitle(/Take Attendance/);
  });

  test('Amara can navigate from dashboard to attendance', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.teacher_id));
    await registryPage.goto('/teacher/');

    // Find an attendance link (if today's events are shown)
    const attendanceLink = registryPage.locator(`a[href*="/teacher/attendance/"]`);
    const count = await attendanceLink.count();

    if (count > 0) {
      await attendanceLink.first().click();
      await registryPage.waitForLoadState('networkidle');
      await expect(registryPage).toHaveURL(/teacher\/attendance/);
    } else {
      // No events today is valid -- the dashboard just shows empty
      test.info().annotations.push({ type: 'skip', description: 'No events shown for today' });
    }
  });

  // The bug this test exists for: the component POSTed with no CSRF token, the
  // before_dispatch hook answered 403, and nothing was recorded. Every other
  // attendance test added the header by hand and never pressed the button, so
  // the register looked taken and was not. This one presses the real button,
  // reads the rows back out of the database, and then reopens the register the
  // way Amara does after lunch -- no header of its own, ever.
  test('Amara marks attendance on the real screen and it is recorded', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.teacher_id));
    await registryPage.goto(`/teacher/attendance/${testData.event_id}`);

    // Both components use an open shadow root, so Playwright's locators reach in.
    const rows = registryPage.locator('student-attendance-row');
    await expect(rows).toHaveCount(testData.student_ids.length);

    // Tap a status per child, taking the ids from the screen rather than the
    // fixture, and mixing present with absent so a server that recorded one
    // blanket status would fail here.
    const ids = await rows.evaluateAll((els) => els.map((el) => el.getAttribute('student-id')));
    const expected = {};
    for (let i = 0; i < ids.length; i++) {
      const status = i === ids.length - 1 ? 'absent' : 'present';
      await rows.nth(i).locator(`button[data-status="${status}"]`).click();
      expected[ids[i]] = status;
    }

    const save = registryPage.locator('attendance-form button#submit-btn');
    await expect(save).toBeEnabled();
    await save.click();

    // The success banner only exists on success; a failure renders .alert-error.
    await expect(registryPage.locator('attendance-form .alert-success')).toBeVisible();

    const recorded = queryJson(
      testDB,
      'registry',
      'SELECT student_id, status, marked_by FROM attendance_records WHERE event_id = ?',
      testData.event_id
    );
    const byStudent = new Map(recorded.map((r) => [r.student_id, r]));

    for (const id of ids) {
      expect(byStudent.get(id)).toMatchObject({
        status: expected[id],
        marked_by: testData.teacher_id,
      });
    }

    // Reopening the register is the other half of taking it: Amara comes back
    // after lunch to correct a child. The page must still render, and each row
    // must come back carrying the mark she made -- an empty register renders no
    // active button at all and fails here.
    await registryPage.reload();
    await expect(rows).toHaveCount(ids.length);

    for (const id of ids) {
      const row = registryPage.locator(`student-attendance-row[student-id="${id}"]`);
      const active = row.locator('button.attendance-btn.active');
      await expect(active).toHaveCount(1);
      await expect(active).toHaveAttribute('data-status', expected[id]);
    }
  });

  test('Amara can mark attendance via the API', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.teacher_id));

    // Get CSRF token from a page load
    await registryPage.goto('/teacher/');
    const csrfToken = await registryPage.locator('meta[name="csrf-token"]').getAttribute('content');

    // POST attendance data -- controller expects flat { student_id: status } hash.
    // attendance_records.student_id has a FK to users, so we use parent_user_id
    // (a real users.id) rather than family_member IDs from student_ids.
    const attendanceData = {
      [testData.parent_user_id]: 'present',
    };

    const response = await registryPage.request.post(
      `/teacher/attendance/${testData.event_id}`,
      {
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken,
        },
        data: attendanceData,
      }
    );

    // Attendance marking should genuinely succeed -- 200/201, NOT a 3xx redirect
    // (a redirect would mean an auth/session failure that we must catch, not pass).
    expect(response.ok()).toBeTruthy();
    expect([200, 201]).toContain(response.status());
  });
});
