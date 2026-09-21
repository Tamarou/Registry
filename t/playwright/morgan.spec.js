// ABOUTME: Morgan's user journey: sign up, build a program, publish it, see it on the storefront.
// ABOUTME: Self-sufficient -- starts from nothing and ends where a parent can find her work.
const { test, expect } = require('./fixtures/base');
const {
  loginToken, queryJson, execSql, loginWithToken, daysFromNow,
} = require('./journey_helpers');

// Serial and ordered: Morgan cannot build a program before she has a tenant to
// build it in. The relay is within one persona now, not across three.
test.describe.configure({ mode: 'serial', timeout: 180000 });

const RUN = String(Date.now());
const state = {
  orgName: `Morgan Arts ${RUN}`,
  morganUsername: `morgan_${RUN}`, morganEmail: `morgan_${RUN}@test.com`,
  amaraUsername: `amara_${RUN}`,   amaraEmail: `amara_${RUN}@test.com`,
};

test.describe('Morgan: from signup to a program a parent can find', () => {
  test('Morgan signs up and her tenant is provisioned', async ({ registryPage, testDB }) => {
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
        // Hidden styled radio -- force past actionability checks.
        await planInput.check({ force: true });
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
  // Leg 1: Morgan builds and publishes a paid program in her tenant
  // ==========================================================================
  test('Morgan creates a program, assigns staff, publishes, and the storefront shows it', async ({ page, testDB }) => {
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

    // Step 1b: curriculum-details. Morgan's first stated goal is programmes that
    // "meet educational standards and students' needs", and the pedagogy fields
    // were the least graded thing she filled in: submitted, then never looked at.
    // They are read back off the project row further down.
    const curriculum = {
      objectives: `Draw from observation and mix secondary colours (${RUN})`,
      materials:  `Newsprint pads, charcoal, tempera paint (${RUN})`,
      skills:     `Observation, colour theory, giving critique (${RUN})`,
    };
    await page.fill('input[name="name"]', state.programName);
    await page.fill('textarea[name="description"]', 'An after-school art program for young artists.');
    await page.fill('textarea[name="learning_objectives"]', curriculum.objectives);
    await page.fill('textarea[name="materials_needed"]', curriculum.materials);
    await page.fill('textarea[name="skills_developed"]', curriculum.skills);
    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/requirements-and-patterns/);

    // Step 1c: requirements-and-patterns. Every field is optional, which is why
    // this screen used to be submitted untouched. Each value below differs from
    // the template's default (blank, 1:10, 1 week, 1/week, 60 min, 15:00), so the
    // read-back cannot pass on a form the step never looked at.
    const requirements = {
      min_age: '6', max_age: '11', min_grade: 'K', max_grade: '5',
      staff_ratio: '1:8', duration_weeks: '4', sessions_per_week: '2',
      session_duration_minutes: '90', default_start_time: '15:45',
    };
    for (const [field, value] of Object.entries(requirements)) {
      await page.fill(`[name="${field}"]`, value);
    }
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

    // Both content screens write into projects.metadata. Run data disappears
    // with the workflow run, so the row is the only place this can be proved.
    const programMeta = queryJson(
      testDB, state.slug,
      `SELECT metadata->'curriculum'->>'learning_objectives' AS objectives,
              metadata->'curriculum'->>'materials_needed'    AS materials,
              metadata->'curriculum'->>'skills_developed'    AS skills,
              metadata->'requirements'->>'min_age'     AS min_age,
              metadata->'requirements'->>'max_age'     AS max_age,
              metadata->'requirements'->>'min_grade'   AS min_grade,
              metadata->'requirements'->>'max_grade'   AS max_grade,
              metadata->'requirements'->>'staff_ratio' AS staff_ratio,
              metadata->'schedule_pattern'->>'duration_weeks'           AS duration_weeks,
              metadata->'schedule_pattern'->>'sessions_per_week'        AS sessions_per_week,
              metadata->'schedule_pattern'->>'session_duration_minutes' AS session_duration_minutes,
              metadata->'schedule_pattern'->>'default_start_time'       AS default_start_time
         FROM projects WHERE id = ?`,
      state.programId
    )[0];
    expect(programMeta, 'curriculum and requirements reached the project row')
      .toEqual({ ...requirements, ...curriculum });

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
    await page.fill('input[name="capacity"]', '24');
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
    const locationRows = queryJson(testDB, state.slug, 'SELECT id, capacity FROM locations WHERE name = ?', `Lifecycle Studio ${RUN}`);
    expect(locationRows.length, 'location row exists in tenant schema').toBeGreaterThan(0);
    state.locationId = locationRows[0].id;
    expect(locationRows[0].capacity, 'the capacity Morgan typed reached the location row').toBe(24);

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

    // Step 3c: configure-location. The per-location capacity pre-fills from the
    // location, so it is read back here and then overridden -- a number the
    // location never had is the only way to show the screen's value is the one
    // the generated session gets.
    const capacityInput = page.locator(`input[name="location_configs[${state.locationId}][capacity]"]`);
    await expect(capacityInput, 'the location capacity pre-fills the per-location field')
      .toHaveValue('24');
    await capacityInput.fill('18');

    // A priced session, not the $0 one this spec used to drive. The paid path is
    // the one that takes money, and the screen offers a single pricing_override
    // per run with a single location, so the free case cannot also be covered
    // here without generating a second session. 29.99 is chosen to separate the
    // dollars-to-cents conversion from every way of skipping it: only
    // int($override * 100 + 0.5) yields 2999.
    const pricingInput = page.locator(`input[name="location_configs[${state.locationId}][pricing_override]"]`);
    await expect(pricingInput).toBeVisible();
    await pricingInput.fill('29.99');

    await page.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
    await expect(page).toHaveURL(/generate-events/);

    // Step 3d: generate-events
    // start_date must be within the next 7 days so Amara's teacher dashboard
    // surfaces the event in Leg 3. Use tomorrow.
    const startDate = daysFromNow(1);
    await page.fill('input[name="generation_params[start_date]"]', startDate);
    await page.fill('input[name="generation_params[duration_weeks]"]', '1');

    // Assign Amara as teacher for the location. Required, not best-effort: if
    // the select never renders then the screen cannot assign anybody, and that
    // is a failure rather than something to step around.
    const teacherSelect = page.locator(`select[name="teacher_assignments[${state.locationId}]"]`);
    await expect(teacherSelect, 'the generate step offers a teacher for the location').toBeVisible();
    await teacherSelect.selectOption(state.amaraId);

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

    // "Assigns staff" has to mean a teacher landed on the events. Since #401 an
    // unassigned event silently falls back to the acting user, so "the event has
    // a teacher" proves nothing: it has to be Amara, and it has to not be the
    // Morgan who was driving the workflow.
    const teacherIds = queryJson(
      testDB, state.slug,
      'SELECT DISTINCT e.teacher_id FROM session_events se JOIN events e ON se.event_id = e.id WHERE se.session_id = ?',
      state.sessionId
    ).map(r => r.teacher_id);
    expect(teacherIds, 'every event of the session is taught by Amara').toEqual([state.amaraId]);
    expect(teacherIds, 'and by nobody else -- the #401 fallback to Morgan must not satisfy this')
      .not.toContain(state.morganId);

    // Capacity has to be the one configured on the screen, not the location
    // default it was pre-filled from.
    const sessionCapacity = queryJson(
      testDB, state.slug, 'SELECT capacity FROM sessions WHERE id = ?', state.sessionId
    )[0].capacity;
    expect(sessionCapacity, 'the generated session carries the configured capacity').toBe(18);

    // The override was typed in dollars and pricing_plans.amount_cents is cents
    // (issue #218: the override used to be collected and dropped).
    const pricingRows = queryJson(
      testDB, state.slug,
      'SELECT amount_cents FROM pricing_plans WHERE session_id = ?',
      state.sessionId
    );
    expect(pricingRows.map(r => r.amount_cents), 'the $29.99 override priced the session at 2999 cents')
      .toEqual([2999]);

    // -----------------------------------------------------------------------
    // Step 4: Publish program then session from the admin dashboard
    // -----------------------------------------------------------------------
    // Pressed, not POSTed. A POST to /admin/programs/:id/status proves the route
    // works while the only control Morgan actually has stays ungraded -- a
    // broken hx-post, a missing CSRF header on the form, or a button that never
    // renders would all have passed.
    const programStatus = () => queryJson(
      testDB, state.slug, 'SELECT status FROM projects WHERE id = ?', state.programId
    )[0].status;
    const sessionStatus = () => queryJson(
      testDB, state.slug, 'SELECT status FROM sessions WHERE id = ?', state.sessionId
    )[0].status;

    expect(programStatus(), 'the program starts unpublished').toBe('draft');
    expect(sessionStatus(), 'and so does its session').toBe('draft');

    // /admin/dashboard is the admin-dashboard WORKFLOW, whose overview
    // HTMX-loads admin-dashboard/program_overview into #program-overview-content.
    await page.goto(`${SUB}/admin/dashboard`);
    await page.waitForLoadState('networkidle');

    // Her events start tomorrow, so the program is not in the default "current"
    // range. "Upcoming" is the tab an owner reaches for to find the thing she
    // has just built and not yet opened.
    await page.getByRole('button', { name: 'Upcoming', exact: true }).click();

    const programCard = page.locator(`div[data-program-id="${state.programId}"]`);
    await expect(programCard, 'her new program is listed').toBeVisible({ timeout: 15000 });

    // The forms are hx-swap="none", so after the click the screen looks
    // identical (#181). Poll the row rather than re-reading the page.
    await programCard.locator('form.publish-toggle')
      .getByRole('button', { name: /^publish$/i }).click();
    await expect.poll(programStatus, { timeout: 10000 }).toBe('published');

    // Generation sets the session's own date range from the events it created
    // (#400), and the storefront filters on it. Read it back rather than
    // writing it: this spec used to UPDATE these dates in and then assert the
    // storefront listed the session, which proved only that the patch worked.
    const sessionDates = queryJson(
      testDB, state.slug,
      'SELECT start_date, end_date FROM sessions WHERE id = ?', state.sessionId
    )[0];
    expect(sessionDates.start_date, 'generation gave the session a start date').toBeTruthy();
    expect(sessionDates.end_date, 'and an end date, which the storefront filters on').toBeTruthy();

    // Publish session (program must be published first -- the session button
    // 409s until the program above is live).
    const sessionRow = page.locator(`li[data-session-id="${state.sessionId}"]`);
    await expect(sessionRow, 'the session is listed under the program').toBeVisible();

    // A priced session meets a gate the $0 one never did: the tenant has to be
    // able to take the money before the session goes on sale. Morgan has not
    // onboarded to Stripe Connect yet, so the first press must be refused.
    const refusal = page.waitForResponse(
      r => r.url().includes(`/admin/sessions/${state.sessionId}/status`)
    );
    await sessionRow.getByRole('button', { name: /^publish$/i }).click();
    expect((await refusal).status(), 'a paid session is refused while the tenant cannot be paid')
      .toBe(409);
    expect(sessionStatus(), 'and it stays in draft').toBe('draft');

    // Connect onboarding is its own journey; this one needs only its result, so
    // the three columns stripe_connect_ready reads are set directly.
    execSql(
      testDB, 'registry',
      `UPDATE registry.tenants
          SET stripe_connect_account_id = ?,
              stripe_charges_enabled    = TRUE,
              stripe_details_submitted  = TRUE
        WHERE slug = ?`,
      `acct_morgan_${RUN}`, state.slug
    );

    await sessionRow.getByRole('button', { name: /^publish$/i }).click();
    await expect.poll(sessionStatus, { timeout: 10000 }).toBe('published');

    // end_date must be in the future for the storefront query
    const sessStatusRows = queryJson(testDB, state.slug,
      'SELECT end_date FROM sessions WHERE id = ?', state.sessionId);
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
    state.regWorkflow = callccMatch ? callccMatch[1] : null;
    expect(state.regWorkflow, 'regWorkflow is summer-camp-registration').toBe('summer-camp-registration');
  });

  // ==========================================================================
  // Leg 2: Nancy discovers Morgan's program and enrolls her child for free
  // ==========================================================================
});
