// ABOUTME: End-to-end test for Morgan's program lifecycle setup journey.
// ABOUTME: Morgan creates a free program, assigns it to a location, and publishes it.

const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

test.describe.configure({ mode: 'serial', timeout: 180000 });

// ---------------------------------------------------------------------------
// Seed helper
// ---------------------------------------------------------------------------
function seedLifecycleData(testDB) {
  const output = execSync(
    'carton exec perl t/playwright/setup_morgan_lifecycle_data.pl',
    {
      cwd: process.cwd(),
      env: { ...process.env, DB_URL: testDB.dbUrl },
      encoding: 'utf8',
    }
  ).trim();

  if (!output) {
    throw new Error('setup_morgan_lifecycle_data.pl produced no output');
  }
  return JSON.parse(output);
}

// ---------------------------------------------------------------------------
// Mint a fresh single-use magic link token.
// Perl sigils must be escaped with \\$ so the shell does not consume them.
// ---------------------------------------------------------------------------
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

  if (!plaintext) throw new Error('freshToken: empty output from Perl helper');
  return plaintext;
}

// ---------------------------------------------------------------------------
// Log in via magic link and wait for redirect.
// ---------------------------------------------------------------------------
async function loginWithToken(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

// ---------------------------------------------------------------------------
// Query the DB for the program (project) id by name.
// Returns the UUID string or throws.
// ---------------------------------------------------------------------------
function queryProgramId(testDB, programName) {
  const script = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db  = \\$dao->db;
    my \\$row = \\$db->select('projects', ['id'], { name => '${programName}' })->hash;
    die 'program not found' unless \\$row;
    print \\$row->{id};
  `;

  const result = execSync(
    `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: process.cwd(), encoding: 'utf8' }
  ).trim();

  if (!result) throw new Error(`queryProgramId: no result for "${programName}"`);
  return result;
}

// ---------------------------------------------------------------------------
// Query the DB for session ids linked to a project via session_events->events.
// Returns an array of UUIDs.
// ---------------------------------------------------------------------------
function querySessionIds(testDB, programId) {
  // Aggregate to a JSON array inside Postgres so this helper only ever handles
  // scalar ($) sigils -- shell double-quoting mangles backslash-escaped @
  // sigils into Perl's declared_refs syntax, which is not enabled here.
  const script = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db  = \\$dao->db;
    my \\$json = \\$db->query(
        q{SELECT COALESCE(json_agg(t.id), '[]'::json)::text AS j FROM (
            SELECT DISTINCT s.id FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            WHERE e.project_id = ? LIMIT 10
          ) t},
        '${programId}'
    )->hash->{j};
    print \\$json;
  `;

  const raw = execSync(
    `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: process.cwd(), encoding: 'utf8' }
  ).trim();

  return JSON.parse(raw);
}

// ---------------------------------------------------------------------------
// Count sessions of a program that satisfy the storefront listing predicate
// (ProgramListing): program + session published, session end_date in the
// future, and a linked pricing plan. Robust against other programs sharing the
// schema. Only scalar ($) sigils so shell double-quoting stays sane.
// ---------------------------------------------------------------------------
function storefrontRegisterableCount(testDB, programName) {
  const script = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db  = \\$dao->db;
    my \\$n = \\$db->query(
        q{SELECT count(DISTINCT s.id) AS c FROM sessions s
          JOIN session_events se ON se.session_id = s.id
          JOIN events e ON e.id = se.event_id
          JOIN projects p ON p.id = e.project_id
          WHERE s.status = 'published' AND p.status = 'published'
            AND s.end_date >= CURRENT_DATE
            AND p.name = ?
            AND EXISTS (SELECT 1 FROM pricing_plans pp WHERE pp.session_id = s.id)},
        '${programName}'
    )->hash->{c};
    print \\$n;
  `;

  const raw = execSync(
    `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: process.cwd(), encoding: 'utf8' }
  ).trim();

  return parseInt(raw, 10);
}

// ---------------------------------------------------------------------------
// Update a session's start_date and end_date so it passes the storefront
// filter (end_date >= CURRENT_DATE). The workflow doesn't set these dates.
// ---------------------------------------------------------------------------
function setSessionDates(testDB, sessionId, startDate, endDate) {
  const script = `
    use lib qw(lib t/lib);
    use Registry::DAO;
    my \\$dao = Registry::DAO->new(url => '${testDB.dbUrl}');
    my \\$db  = \\$dao->db;
    \\$db->update('sessions',
        { start_date => '${startDate}', end_date => '${endDate}' },
        { id => '${sessionId}' }
    );
    print 'ok';
  `;

  return execSync(
    `carton exec perl -e "${script.trim().replace(/\n\s*/g, ' ')}"`,
    { cwd: process.cwd(), encoding: 'utf8' }
  ).trim();
}

// ===========================================================================
// Morgan's Program Setup Journey
// ===========================================================================
test.describe("Morgan's program setup journey", () => {
  let testData;
  let programName;
  let programId;
  let sessionIds;

  test.beforeAll(async ({ testDB }) => {
    testData = seedLifecycleData(testDB);
    // Unique name tied to the seed run for DB lookup after creation
    programName = `Lifecycle Art Program ${testData.ts}`;
  });

  // -------------------------------------------------------------------------
  // 1. Login
  // -------------------------------------------------------------------------
  test('Morgan logs in via magic link', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.morgan.user_id));
    await expect(registryPage).toHaveURL(/\//);
  });

  // -------------------------------------------------------------------------
  // 2. Full program creation workflow in one test
  //    Route: /program-creation (workflow slug: program-creation)
  //    Steps: program-type-selection -> curriculum-details ->
  //           requirements-and-patterns -> review-and-create -> complete
  // -------------------------------------------------------------------------
  test('Morgan creates a program via program-creation workflow', async ({ registryPage, testDB }) => {
    await loginWithToken(registryPage, freshToken(testDB, testData.morgan.user_id));

    // Start: GET /program-creation creates a new workflow run and shows step 1
    await registryPage.goto('/program-creation');
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('h2')).toContainText('Create New Program');

    // Step 1: program-type-selection
    // Field: input[name="program_type_slug"] (radio)
    const radio = registryPage.locator('input[name="program_type_slug"][value="afterschool"]');
    await expect(radio).toBeVisible();
    await radio.check();
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage).toHaveURL(/curriculum-details/);

    // Step 2: curriculum-details
    // Fields: name, description (required); learning_objectives, materials_needed, skills_developed (optional)
    await registryPage.fill('input[name="name"]', programName);
    await registryPage.fill('textarea[name="description"]', 'A free after-school art program for young artists.');
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage).toHaveURL(/requirements-and-patterns/);

    // Step 3: requirements-and-patterns
    // All fields optional; submit with defaults
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage).toHaveURL(/review-and-create/);

    // Step 4: review-and-create — confirm button (name="confirm" value="1")
    await registryPage.locator('button[name="confirm"][value="1"]').click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage).toHaveURL(/complete/);
    await expect(registryPage.locator('h2')).toContainText('Program Created Successfully');
  });

  // -------------------------------------------------------------------------
  // 3. Full program-location-assignment workflow in one test
  //    Route: /program-location-assignment
  //    Steps: select-program -> choose-locations -> configure-location ->
  //           generate-events -> complete
  // -------------------------------------------------------------------------
  test('Morgan assigns program to location and generates free sessions', async ({ registryPage, testDB }) => {
    // Resolve the program that was just created
    programId = queryProgramId(testDB, programName);
    expect(programId).toBeTruthy();

    await loginWithToken(registryPage, freshToken(testDB, testData.morgan.user_id));

    // Start: GET /program-location-assignment
    await registryPage.goto('/program-location-assignment');
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage.locator('h2')).toContainText('Select Program');

    // Step 1: select-program — field: input[name="project_id"] (radio)
    const programRadio = registryPage.locator(`input[name="project_id"][value="${programId}"]`);
    await expect(programRadio).toBeVisible();
    await programRadio.check();
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage).toHaveURL(/choose-locations/);

    // Step 2: choose-locations — field: input[name="location_ids"] (checkbox)
    const locationCheckbox = registryPage.locator(`input[name="location_ids"][value="${testData.location_id}"]`);
    await expect(locationCheckbox).toBeVisible();
    await locationCheckbox.check();
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage).toHaveURL(/configure-location/);

    // Step 3: configure-location
    // Fields: location_configs[<id>][capacity] (required), location_configs[<id>][pricing_override]
    // Set pricing_override = 0 for a free session (issue #218 fix creates a $0 pricing_plans row)
    const capacityInput = registryPage.locator(
      `input[name="location_configs[${testData.location_id}][capacity]"]`
    );
    await expect(capacityInput).toBeVisible();
    await capacityInput.fill('20');

    const pricingInput = registryPage.locator(
      `input[name="location_configs[${testData.location_id}][pricing_override]"]`
    );
    await expect(pricingInput).toBeVisible();
    await pricingInput.fill('0');

    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');
    await expect(registryPage).toHaveURL(/generate-events/);

    // Step 4: generate-events
    // Fields: generation_params[start_date] (date), generation_params[duration_weeks], confirm_generation
    await registryPage.fill('input[name="generation_params[start_date]"]', '2026-09-01');
    await registryPage.fill('input[name="generation_params[duration_weeks]"]', '4');

    // Assign Amara as the teacher for the location. The events table requires a
    // teacher_id, and Amara takes attendance for these events in a later leg.
    await registryPage.selectOption(
      `select[name="teacher_assignments[${testData.location_id}]"]`,
      testData.amara.user_id
    );

    await registryPage.locator('input[name="confirm_generation"]').check();
    await registryPage.locator('button[type="submit"]').click();
    await registryPage.waitForLoadState('networkidle');

    // Complete
    await expect(registryPage).toHaveURL(/complete/);
    await expect(
      registryPage.getByRole('heading', { level: 1, name: 'Program Assignment Complete!' })
    ).toBeVisible();
  });

  // -------------------------------------------------------------------------
  // 4. Publish program then session via admin API
  //    Routes: POST /admin/programs/:id/status, POST /admin/sessions/:id/status
  // -------------------------------------------------------------------------
  test('Morgan publishes the program via admin API', async ({ registryPage, testDB }) => {
    if (!programId) programId = queryProgramId(testDB, programName);

    await loginWithToken(registryPage, freshToken(testDB, testData.morgan.user_id));

    // Load the admin dashboard to get a CSRF token
    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');
    const csrfToken = await registryPage.locator('meta[name="csrf-token"]').getAttribute('content');
    expect(csrfToken).toBeTruthy();

    // POST /admin/programs/:id/status with status=published
    const response = await registryPage.request.post(
      `/admin/programs/${programId}/status`,
      {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-CSRF-Token': csrfToken,
        },
        form: { status: 'published' },
      }
    );

    expect(response.ok()).toBeTruthy();
    const body = await response.json();
    expect(body.status).toBe('published');
  });

  test('Morgan publishes the session via admin API', async ({ registryPage, testDB }) => {
    if (!programId) programId = queryProgramId(testDB, programName);

    // Find the sessions created by the workflow
    sessionIds = querySessionIds(testDB, programId);
    expect(sessionIds.length).toBeGreaterThan(0);

    const sessionId = sessionIds[0];

    // The workflow does not set start_date/end_date on the session.
    // Set future dates so the storefront query (end_date >= CURRENT_DATE) passes.
    setSessionDates(testDB, sessionId, '2026-09-01', '2026-11-30');

    await loginWithToken(registryPage, freshToken(testDB, testData.morgan.user_id));
    await registryPage.goto('/admin/dashboard');
    await registryPage.waitForLoadState('networkidle');
    const csrfToken = await registryPage.locator('meta[name="csrf-token"]').getAttribute('content');
    expect(csrfToken).toBeTruthy();

    // POST /admin/sessions/:id/status with status=published
    // The program must already be published (done in previous test).
    const response = await registryPage.request.post(
      `/admin/sessions/${sessionId}/status`,
      {
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-CSRF-Token': csrfToken,
        },
        form: { status: 'published' },
      }
    );

    expect(response.ok()).toBeTruthy();
    const body = await response.json();
    expect(body.status).toBe('published');
  });

  // -------------------------------------------------------------------------
  // 5. Verify the free published session is registerable on the storefront.
  //    "Registerable" == it satisfies the storefront listing query
  //    (ProgramListing): program + session both published, session end_date in
  //    the future, and a linked pricing plan. We assert that predicate directly
  //    against the DB (so the check is robust regardless of how many other
  //    programs share the registry schema) and confirm the storefront renders.
  //
  //    Pre-foundation, Morgan's data lives in the shared registry schema, so we
  //    cannot assert his session is the *first* card the marketing template
  //    renders (that only holds once a tenant has its own schema). Asserting the
  //    storefront predicate is the contamination-proof equivalent.
  // -------------------------------------------------------------------------
  test('Published free session is registerable on the storefront', async ({ registryPage, testDB }) => {
    // The storefront listing predicate, scoped to Morgan's program.
    const count = storefrontRegisterableCount(testDB, programName);
    expect(count, 'Morgan\'s published free session satisfies the storefront query').toBeGreaterThan(0);

    // And the storefront itself renders (no 500) for an unauthenticated visitor.
    await registryPage.context().clearCookies();
    const res = await registryPage.goto('/');
    expect(res.status(), 'storefront renders').toBe(200);
    await expect(registryPage.locator('body')).not.toContainText('An Error Occurred');
  });
});
