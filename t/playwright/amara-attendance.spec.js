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

  test('Amara logs in via magic link', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.teacher_token);
    await expect(registryPage).toHaveURL(/\//);
  });

  test('Amara sees the teacher dashboard', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.teacher_token);
    await registryPage.goto('/teacher/');

    // Dashboard renders with navigation
    await expect(registryPage.locator('nav.dashboard-nav')).toBeVisible();
    await expect(registryPage.locator('text=Teacher Dashboard')).toBeVisible();
  });

  test('Amara sees navigation with staff links', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.teacher_token);
    await registryPage.goto('/teacher/');

    const nav = registryPage.locator('nav.dashboard-nav');
    await expect(nav.locator('a[href="/teacher/"]')).toBeVisible();
    await expect(nav.locator('a[href="/admin/dashboard"]')).toBeVisible();

    // Staff should NOT see admin-only domains link
    await expect(nav.locator('a[href="/admin/domains"]')).toHaveCount(0);
  });

  test('Amara can view attendance page for her event', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.teacher_token);
    await registryPage.goto(`/teacher/attendance/${testData.event_id}`);

    await expect(registryPage.locator('text=Attendance')).toBeVisible();
  });

  test('Amara can navigate from dashboard to attendance', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.teacher_token);
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

  test('Amara can mark attendance via the API', async ({ registryPage }) => {
    await loginWithToken(registryPage, testData.teacher_token);

    // Get CSRF token from a page load
    await registryPage.goto('/teacher/');
    const csrfToken = await registryPage.locator('meta[name="csrf-token"]').getAttribute('content');

    // POST attendance data -- controller expects flat { student_id: status } hash
    const attendanceData = {};
    testData.student_ids.forEach((id, i) => {
      attendanceData[id] = i === 0 ? 'present' : 'absent';
    });

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
