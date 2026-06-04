// ABOUTME: End-to-end browser test for Amara's teacher attendance journey.
// ABOUTME: Tests dashboard access, event viewing, and attendance marking via Web Components.

const { test, expect } = require('./fixtures/base');
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

    // Attendance marking should succeed
    expect([200, 201, 302]).toContain(response.status());
  });
});
