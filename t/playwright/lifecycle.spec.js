// ABOUTME: Serial lifecycle E2E — Morgan signs up, builds a free program; Nancy
// ABOUTME: enrolls her child; Amara takes attendance — all in Morgan's tenant schema.
const { test, expect } = require('./fixtures/base');
const { execFileSync } = require('child_process');

function helper(testDB, args) {
  return execFileSync(
    'carton',
    ['exec', 'perl', 't/playwright/lifecycle_helpers.pl', ...args],
    { cwd: process.cwd(), env: { ...process.env, DB_URL: testDB.dbUrl }, encoding: 'utf8' }
  ).trim();
}
function loginToken(testDB, schema, userId) { return helper(testDB, ['login-token', schema, userId]); }
function queryJson(testDB, schema, sql, ...bind) { return JSON.parse(helper(testDB, ['query-json', schema, sql, ...bind.map(String)])); }
function execSql(testDB, schema, sql, ...bind) { return helper(testDB, ['exec-sql', schema, sql, ...bind.map(String)]); }

async function loginWithToken(page, token, baseUrl = '') {
  await page.goto(`${baseUrl}/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

test.describe.configure({ mode: 'serial', timeout: 180000 });

const RUN = String(Date.now());
const state = {
  orgName: `Lifecycle Arts ${RUN}`,
  morganUsername: `morgan_${RUN}`, morganEmail: `morgan_${RUN}@test.com`,
  amaraUsername: `amara_${RUN}`,   amaraEmail: `amara_${RUN}@test.com`,
  nancyUsername: `nancy_${RUN}`,   nancyEmail: `nancy_${RUN}@test.com`,
  childName: `Kid ${RUN}`,
};

test.describe('Lifecycle: Morgan -> Nancy -> Amara', () => {

  // Helper: derive a date string N days from today in YYYY-MM-DD format.
  function daysFromNow(n) {
    const d = new Date();
    d.setDate(d.getDate() + n);
    return d.toISOString().split('T')[0];
  }

  test('Leg 0: Morgan signs up and her tenant is provisioned', async ({ registryPage, testDB }) => {
    // Clear session so we always get a fresh workflow run
    await registryPage.context().clearCookies();

    // ----------------------------------------------------------------
    // Landing step
    // ----------------------------------------------------------------
    await registryPage.goto('/tenant-signup');
    await registryPage.waitForLoadState('networkidle');
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Profile step
    // ----------------------------------------------------------------
    await expect(registryPage.locator('input[name="name"]')).toBeVisible({ timeout: 5000 });
    await registryPage.fill('input[name="name"]', state.orgName);
    await registryPage.fill('input[name="billing_email"]', state.morganEmail);
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Users step — fill Morgan's admin account and invite Amara as staff
    // ----------------------------------------------------------------
    await expect(registryPage.locator('input[name="admin_name"]')).toBeVisible({ timeout: 5000 });
    await registryPage.fill('input[name="admin_name"]', 'Morgan Admin');
    await registryPage.fill('input[name="admin_email"]', state.morganEmail);
    await registryPage.fill('input[name="admin_username"]', state.morganUsername);

    // Click "Add Team Member" to inject the dynamic card for Amara
    await registryPage.click('#add-member-btn');
    await registryPage.waitForTimeout(300); // let JS render the card

    // Fill the dynamically-inserted first team member card (index 0)
    await registryPage.fill('input[name="team_members[0][name]"]', 'Amara Teacher');
    await registryPage.fill('input[name="team_members[0][email]"]', state.amaraEmail);
    // Role select defaults to "staff"; ensure it is set explicitly
    await registryPage.selectOption('select[name="team_members[0][user_type]"]', 'staff');

    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Pricing step (optional — skipped when no plans are configured)
    // ----------------------------------------------------------------
    const pricingVisible = await registryPage.locator('h1, h2').filter({ hasText: /plan|pricing/i })
      .isVisible({ timeout: 2000 }).catch(() => false);
    if (pricingVisible) {
      const planInput = registryPage.locator('input[name="selected_plan_id"]').first();
      if (await planInput.isVisible({ timeout: 1000 }).catch(() => false)) {
        await planInput.check();
      }
      await registryPage.click('button[type="submit"]');
      await registryPage.waitForLoadState('networkidle');
    }

    // ----------------------------------------------------------------
    // Review step — check terms and click the JS-gated proceed button
    // ----------------------------------------------------------------
    const termsInput = registryPage.locator('input[name="terms_accepted"]');
    if (await termsInput.isVisible({ timeout: 3000 }).catch(() => false)) {
      await termsInput.check();
      const proceedBtn = registryPage.locator('#proceed-to-payment');
      await expect(proceedBtn).toBeEnabled({ timeout: 5000 });
      await proceedBtn.click();
      await registryPage.waitForLoadState('networkidle');
    }

    // ----------------------------------------------------------------
    // Payment step — no Stripe keys in test mode, provisions directly
    // ----------------------------------------------------------------
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/payment|add payment method|trial/i, { timeout: 5000 });

    const paymentSubmit = registryPage.locator('button[type="submit"]').first();
    await expect(paymentSubmit).toBeVisible({ timeout: 10000 });
    await paymentSubmit.click();
    await registryPage.waitForLoadState('networkidle', { timeout: 15000 });

    // ----------------------------------------------------------------
    // Completion — assert welcome page rendered
    // ----------------------------------------------------------------
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/welcome to registry/i, { timeout: 10000 });

    // ----------------------------------------------------------------
    // Capture state.slug from the DB (do not derive in JS)
    // ----------------------------------------------------------------
    const slugRows = queryJson(testDB, 'registry', 'SELECT slug FROM tenants WHERE name = ?', state.orgName);
    expect(slugRows.length, 'tenant row exists in registry.tenants').toBeGreaterThan(0);
    state.slug = slugRows[0].slug;

    // Slug must be subdomain-routable: lowercase letters/digits/underscores, starts with a letter
    expect(state.slug, 'slug matches /^[a-z][a-z0-9_]+$/').toMatch(/^[a-z][a-z0-9_]+$/);

    // ----------------------------------------------------------------
    // Amara-in-tenant gate: Amara must exist in the tenant schema
    // ----------------------------------------------------------------
    const staffRows = queryJson(testDB, state.slug, 'SELECT id FROM users WHERE user_type = ?', 'staff');
    expect(staffRows.length, 'at least one staff user in tenant schema').toBeGreaterThan(0);
    state.amaraId = staffRows[0].id;

    const adminRows = queryJson(testDB, state.slug, 'SELECT id FROM users WHERE user_type = ?', 'admin');
    expect(adminRows.length, 'at least one admin user in tenant schema').toBeGreaterThan(0);
    state.morganId = adminRows[0].id;

    // ----------------------------------------------------------------
    // Workflows gate: tenant schema must include the workflows later legs need
    // ----------------------------------------------------------------
    const workflowRows = queryJson(testDB, state.slug, 'SELECT slug FROM workflows');
    const workflowSlugs = workflowRows.map(r => r.slug);
    expect(workflowSlugs, 'program-creation workflow exists').toContain('program-creation');
    expect(workflowSlugs, 'program-location-assignment workflow exists').toContain('program-location-assignment');
    expect(workflowSlugs, 'summer-camp-registration workflow exists').toContain('summer-camp-registration');
  });

  // ==========================================================================
  // Leg 1: Morgan builds and publishes a free program in her tenant
  // ==========================================================================
  test('Leg 1: Morgan creates a program, location, assigns + publishes, storefront shows it', async ({ page, testDB }) => {
    const SUB = `http://${state.slug}.localhost:3001`;

    // -----------------------------------------------------------------------
    // GATE: login on subdomain using a tenant-schema token
    // -----------------------------------------------------------------------
    const morganToken = loginToken(testDB, state.slug, state.morganId);
    await loginWithToken(page, morganToken, SUB);
    // After consuming the magic link the auth controller redirects to '/'.
    // Navigate to /admin/dashboard explicitly to confirm the session is live.
    await page.goto(`${SUB}/admin/dashboard`);
    await page.waitForLoadState('networkidle');
    await expect(page.locator('body')).not.toContainText('Internal Server Error');
    await expect(page.locator('body')).not.toContainText('An Error Occurred');
    // Confirm this is an authenticated admin page
    await expect(page.locator('meta[name="csrf-token"]')).toBeAttached();

    // -----------------------------------------------------------------------
    // Step 1: Create program via program-creation workflow
    // -----------------------------------------------------------------------
    state.programName = `Lifecycle Art ${RUN}`;

    await page.goto(`${SUB}/program-creation`);
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h2')).toContainText('Create New Program');

    // Step 1a: program-type-selection
    const radio = page.locator('input[name="program_type_slug"][value="afterschool"]');
    await expect(radio).toBeVisible();
    await radio.check();
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/curriculum-details/);

    // Step 1b: curriculum-details
    await page.fill('input[name="name"]', state.programName);
    await page.fill('textarea[name="description"]', 'A free after-school art program for young artists.');
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/requirements-and-patterns/);

    // Step 1c: requirements-and-patterns (all optional — submit with defaults)
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/review-and-create/);

    // Step 1d: review-and-create
    await page.locator('button[name="confirm"][value="1"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/complete/);
    await expect(page.locator('h2')).toContainText('Program Created Successfully');

    // Capture program id
    const programRows = queryJson(testDB, state.slug, 'SELECT id FROM projects WHERE name = ?', state.programName);
    expect(programRows.length, 'program row exists in tenant schema').toBeGreaterThan(0);
    state.programId = programRows[0].id;

    // -----------------------------------------------------------------------
    // Step 2: Create a location via location-management workflow
    // -----------------------------------------------------------------------
    await page.goto(`${SUB}/location-management`);
    await page.waitForLoadState('networkidle');
    // list-or-create step: submit action=new to go to location-details
    await expect(page.locator('h2')).toContainText('Locations');
    const newLocBtn = page.locator('button[type="submit"]').filter({ hasText: /create new location/i });
    await expect(newLocBtn).toBeVisible();
    await newLocBtn.click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/location-details/);

    // location-details step: fill name + address
    await expect(page.locator('input[name="name"]')).toBeVisible();
    await page.fill('input[name="name"]', `Lifecycle Studio ${RUN}`);
    await page.fill('input[name="street_address"]', '123 Art Lane');
    await page.fill('input[name="city"]', 'Orlando');
    await page.fill('input[name="state"]', 'FL');
    await page.fill('input[name="postal_code"]', '32801');
    await page.fill('input[name="capacity"]', '20');
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/select-contact/);

    // select-contact step: use Morgan as contact (existing user)
    await expect(page.locator('select[name="contact_id"]')).toBeVisible();
    // Pick Morgan by her user id
    await page.selectOption('select[name="contact_id"]', state.morganId);
    // contact_mode radio: 'existing' should be checked by default, confirm it
    const existingRadio = page.locator('input[name="contact_mode"][value="existing"]');
    if (await existingRadio.isVisible()) {
      await existingRadio.check();
    }
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/complete/);
    await expect(page.locator('h2')).toContainText('Location saved');

    // Capture location id from tenant schema
    const locationRows = queryJson(testDB, state.slug, 'SELECT id FROM locations WHERE name = ?', `Lifecycle Studio ${RUN}`);
    expect(locationRows.length, 'location row exists in tenant schema').toBeGreaterThan(0);
    state.locationId = locationRows[0].id;

    // -----------------------------------------------------------------------
    // Step 3: Assign + generate via program-location-assignment
    // -----------------------------------------------------------------------
    await page.goto(`${SUB}/program-location-assignment`);
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h2')).toContainText('Select Program');

    // Step 3a: select-program
    const programRadio = page.locator(`input[name="project_id"][value="${state.programId}"]`);
    await expect(programRadio).toBeVisible();
    await programRadio.check();
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/choose-locations/);

    // Step 3b: choose-locations
    const locationCheckbox = page.locator(`input[name="location_ids"][value="${state.locationId}"]`);
    await expect(locationCheckbox).toBeVisible();
    await locationCheckbox.check();
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/configure-location/);

    // Step 3c: configure-location (capacity + $0 pricing override)
    const capacityInput = page.locator(`input[name="location_configs[${state.locationId}][capacity]"]`);
    await expect(capacityInput).toBeVisible();
    await capacityInput.fill('20');

    const pricingInput = page.locator(`input[name="location_configs[${state.locationId}][pricing_override]"]`);
    await expect(pricingInput).toBeVisible();
    await pricingInput.fill('0');

    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/generate-events/);

    // Step 3d: generate-events
    // start_date must be within the next 7 days so Amara's teacher dashboard
    // surfaces the event in Leg 3. Use tomorrow.
    const startDate = daysFromNow(1);
    await page.fill('input[name="generation_params[start_date]"]', startDate);
    await page.fill('input[name="generation_params[duration_weeks]"]', '1');

    // Assign Amara as teacher for the location
    const teacherSelect = page.locator(`select[name="teacher_assignments[${state.locationId}]"]`);
    if (await teacherSelect.isVisible({ timeout: 2000 }).catch(() => false)) {
      await teacherSelect.selectOption(state.amaraId);
    }

    await page.locator('input[name="confirm_generation"]').check();
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/complete/);
    await expect(page.getByRole('heading', { level: 1, name: 'Program Assignment Complete!' })).toBeVisible();

    // Capture session id
    const sessionRows = queryJson(
      testDB, state.slug,
      'SELECT DISTINCT s.id FROM sessions s JOIN session_events se ON se.session_id = s.id JOIN events e ON e.id = se.event_id WHERE e.project_id = ?',
      state.programId
    );
    expect(sessionRows.length, 'at least one session generated').toBeGreaterThan(0);
    state.sessionId = sessionRows[0].id;

    // Capture first event id
    const eventRows = queryJson(
      testDB, state.slug,
      'SELECT e.id FROM session_events se JOIN events e ON se.event_id = e.id WHERE se.session_id = ? ORDER BY e.time LIMIT 1',
      state.sessionId
    );
    expect(eventRows.length, 'at least one event generated').toBeGreaterThan(0);
    state.eventId = eventRows[0].id;

    // Verify pricing plan with amount=0 exists (issue #218 free plan)
    const pricingRows = queryJson(
      testDB, state.slug,
      'SELECT id FROM pricing_plans WHERE session_id = ? AND amount = 0',
      state.sessionId
    );
    expect(pricingRows.length, 'free ($0) pricing plan exists for session').toBeGreaterThan(0);

    // -----------------------------------------------------------------------
    // Step 4: Publish program then session via admin API
    // -----------------------------------------------------------------------
    await page.goto(`${SUB}/admin/dashboard`);
    await page.waitForLoadState('networkidle');
    const csrfToken = await page.locator('meta[name="csrf-token"]').getAttribute('content');
    expect(csrfToken).toBeTruthy();

    // Publish program
    const progResp = await page.request.post(`${SUB}/admin/programs/${state.programId}/status`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-CSRF-Token': csrfToken,
      },
      form: { status: 'published' },
    });
    expect(progResp.ok(), 'program publish response ok').toBeTruthy();
    const progBody = await progResp.json();
    expect(progBody.status).toBe('published');

    // Set future start_date and end_date on the session so the storefront
    // query (end_date >= CURRENT_DATE) passes. Use near-future dates so Amara's
    // teacher dashboard also surfaces the event in Leg 3.
    const endDate = daysFromNow(7);
    // Use execSql (not queryJson) because data-modifying CTEs cannot appear
    // inside the json_agg subquery wrapper that queryJson uses.
    const updateResult = execSql(
      testDB, state.slug,
      `UPDATE sessions SET start_date = ?, end_date = ? WHERE id = ?`,
      startDate, endDate, state.sessionId
    );
    expect(updateResult, 'session dates updated').toBe('ok');

    // Publish session (program must be published first)
    const sessResp = await page.request.post(`${SUB}/admin/sessions/${state.sessionId}/status`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-CSRF-Token': csrfToken,
      },
      form: { status: 'published' },
    });
    expect(sessResp.ok(), 'session publish response ok').toBeTruthy();
    const sessBody = await sessResp.json();
    expect(sessBody.status).toBe('published');

    // Verify the publish + date state in the tenant schema before checking the storefront.
    const progStatusRows = queryJson(testDB, state.slug,
      'SELECT status FROM projects WHERE id = ?', state.programId);
    expect(progStatusRows[0]?.status, 'program status is published in tenant schema').toBe('published');

    const sessStatusRows = queryJson(testDB, state.slug,
      'SELECT status, end_date FROM sessions WHERE id = ?', state.sessionId);
    expect(sessStatusRows[0]?.status, 'session status is published in tenant schema').toBe('published');
    // end_date must be in the future for the storefront query
    expect(sessStatusRows[0]?.end_date, 'session end_date is set').toBeTruthy();

    // -----------------------------------------------------------------------
    // Step 5: Storefront registerable check (unauthenticated)
    // -----------------------------------------------------------------------

    // Verify the storefront query would find results before visiting the page.
    const storefrontQueryRows = queryJson(testDB, state.slug,
      `SELECT s.id FROM sessions s
       JOIN session_events se ON se.session_id = s.id
       JOIN events e ON e.id = se.event_id
       JOIN projects p ON p.id = e.project_id
       JOIN locations l ON l.id = e.location_id
       WHERE s.status = 'published' AND p.status = 'published'
         AND s.end_date >= CURRENT_DATE`
    );
    expect(storefrontQueryRows.length, 'storefront query returns at least one row').toBeGreaterThan(0);

    await page.context().clearCookies();
    const storefrontRes = await page.goto(`${SUB}/`);
    expect(storefrontRes.status(), 'storefront renders').toBe(200);
    await expect(page.locator('body')).not.toContainText('Internal Server Error');
    await expect(page.locator('body')).not.toContainText('An Error Occurred');

    // The tenant storefront uses a marketing page template that shows the
    // program's session_id inside CTA registration forms (the template renders
    // the form in both the hero section and the alignment section).
    // Use .first() to avoid strict-mode failures when there are multiple forms.
    const sessionInputLocator = page.locator(`form input[name="session_id"][value="${state.sessionId}"]`).first();
    await expect(
      sessionInputLocator,
      'storefront form carries the session_id'
    ).toBeAttached({ timeout: 10000 });

    // Capture the registration workflow from the form action (callcc target)
    const allForms = await page.locator(`form:has(input[name="session_id"][value="${state.sessionId}"])`).all();
    expect(allForms.length, 'at least one CTA form with session_id on storefront').toBeGreaterThan(0);
    const formAction = await allForms[0].getAttribute('action');
    expect(formAction, 'form action is set').toBeTruthy();
    // action is e.g. "/tenant-storefront/<run_id>/callcc/<workflow>"
    const callccMatch = (formAction || '').match(/callcc\/([^/]+)$/);
    expect(callccMatch, 'form action contains callcc target').toBeTruthy();
    state.regWorkflow = callccMatch ? callccMatch[1] : 'summer-camp-registration';
    expect(state.regWorkflow, 'regWorkflow captured').toBeTruthy();
  });

});
