// ABOUTME: The acquisition seam: Alex's funnel hands a working tenant to Jordan, who
// ABOUTME: invited Morgan -- and Morgan, who never signed up, has to be able to work in it.
const { test, expect } = require('./fixtures/base');
const {
  loginToken, queryJson, loginWithToken,
} = require('./journey_helpers');

// The funnel collects team members and mints each an invite token. Delivery is
// a TODO -- _send_invitation_email logs "Would send invitation email to" and
// stops -- so this journey mints the token the way lifecycle does rather than
// reading a mailbox. What it proves is the rest: that an invited person can
// reach the tenant and do the job they were invited for.
//
// lifecycle already covers an invited TEACHER marking attendance. Nobody
// covers an invited ADMIN, which is the Jordan-owns / Morgan-manages split the
// funnel's user_type select exists for.
test.describe.configure({ mode: 'serial', timeout: 180000 });

const RUN = String(Date.now());
const state = {
  orgName: `Team Arts ${RUN}`,
  jordanUsername: `jordan_${RUN}`, jordanEmail: `jordan_${RUN}@test.com`,
  morganUsername: `morgan_${RUN}`, morganEmail: `morgan_${RUN}@test.com`,
};

test.describe('Alex to Jordan to Morgan: an acquired tenant is a workable one', () => {
  test('Jordan signs up and his tenant is provisioned with Morgan on the team', async ({ registryPage, testDB }) => {
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
    await registryPage.fill('input[name="billing_email"]', state.jordanEmail);
    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Users step — fill Morgan's admin account and invite Amara as staff
    // ----------------------------------------------------------------
    await expect(registryPage.locator('input[name="admin_name"]')).toBeVisible({ timeout: 5000 });
    await registryPage.fill('input[name="admin_name"]', 'Jordan Owner');
    await registryPage.fill('input[name="admin_email"]', state.jordanEmail);
    await registryPage.fill('input[name="admin_username"]', state.jordanUsername);

    // Click "Add Team Member" to inject the dynamic card for Amara
    await registryPage.click('#add-member-btn');
    await registryPage.waitForTimeout(300); // let JS render the card

    // Fill the dynamically-inserted first team member card (index 0)
    await registryPage.fill('input[name="team_members[0][name]"]', 'Morgan Manager');
    await registryPage.fill('input[name="team_members[0][email]"]', state.morganEmail);
    // Role select defaults to "staff"; ensure it is set explicitly
    await registryPage.selectOption('select[name="team_members[0][user_type]"]', 'admin');

    await registryPage.click('button[type="submit"]');
    await registryPage.waitForLoadState('networkidle');

    // ----------------------------------------------------------------
    // Review step — the last page. Checking terms enables the button, and the
    // button provisions: nobody picks a plan and nobody is asked for a card.
    // ----------------------------------------------------------------
    const termsInput = registryPage.locator('input[name="terms_accepted"]');
    await expect(termsInput).toBeVisible({ timeout: 5000 });
    await termsInput.check();
    const proceedBtn = registryPage.locator('#create-studio');
    await expect(proceedBtn).toBeEnabled({ timeout: 5000 });
    await proceedBtn.click();
    await registryPage.waitForLoadState('networkidle', { timeout: 15000 });

    // ----------------------------------------------------------------
    // Completion — assert welcome page rendered
    // ----------------------------------------------------------------
    await expect(registryPage.locator('body')).not.toContainText('Internal Server Error');
    await expect(registryPage.locator('body')).toContainText(/your studio is live/i, { timeout: 10000 });

    // ----------------------------------------------------------------
    // Capture state.slug from the DB (do not derive in JS)
    // ----------------------------------------------------------------
    const slugRows = queryJson(testDB, 'registry', 'SELECT slug FROM tenants WHERE name = ?', state.orgName);
    expect(slugRows.length, 'tenant row exists in registry.tenants').toBeGreaterThan(0);
    state.slug = slugRows[0].slug;

    // Slug must be subdomain-routable: lowercase letters/digits/underscores, starts with a letter
    expect(state.slug, 'slug matches /^[a-z][a-z0-9_]+$/').toMatch(/^[a-z][a-z0-9_]+$/);

    // ----------------------------------------------------------------
    // Both people the funnel was told about must exist in the tenant: the
    // owner who filled the form, and the person he named on it. Told apart by
    // username, because email lives on user_profiles and not on users.
    // ----------------------------------------------------------------
    const admins = queryJson(testDB, state.slug,
      'SELECT id, username FROM users WHERE user_type = ?', 'admin');
    expect(admins.length, 'the owner and the person he invited').toBe(2);

    const jordan = admins.find(u => u.username === state.jordanUsername);
    const morgan = admins.find(u => u.username !== state.jordanUsername);
    expect(jordan, 'the owner, by the username he chose').toBeTruthy();
    expect(morgan, 'and the invited member beside him').toBeTruthy();

    state.jordanId = jordan.id;
    state.morganId = morgan.id;

    // No invitation was SENT, deliberately. Signup is anonymous and the
    // team-member address is whatever the person filling in the form typed, so
    // mailing it made the form an outbound mailer for recipients the caller
    // chose -- our sending domain, a working magic link, a tenant the recipient
    // never asked to join (#438). Jordan sends it from /admin/people once he
    // has signed in, which is proof he holds the address he signed up with.
    const invites = queryJson(testDB, state.slug,
      "SELECT metadata FROM notifications WHERE user_id = ? AND type = ?",
      morgan.id, 'magic_link_invite');
    expect(invites.length, 'the anonymous signup mailed her nothing').toBe(0);

    // She is on the team and marked as still needing one, which is what lets
    // the People screen tell "not invited yet" from "invited".
    const pending = queryJson(testDB, state.slug,
      'SELECT invite_pending FROM users WHERE id = ?', morgan.id);
    expect(pending[0].invite_pending, 'and is marked as not yet invited')
      .toBeTruthy();

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

  // The owner, on the subdomain he was just sold.
  test('Jordan can reach his own dashboard', async ({ page, testDB }) => {
    const SUB = `http://${state.slug}.localhost:3001`;

    await loginWithToken(page, loginToken(testDB, state.slug, state.jordanId), SUB);
    await page.goto(`${SUB}/admin/dashboard`);
    await page.waitForLoadState('networkidle');

    await expect(page.locator('body')).not.toContainText('Internal Server Error');
    await expect(page.locator('body')).toContainText(/dashboard/i);
  });

  // Morgan never signed up. She was named on someone else's form, and the
  // product's claim is that she can then run programs in their tenant.
  test('Morgan, who was invited, can work in the tenant', async ({ page, testDB }) => {
    const SUB = `http://${state.slug}.localhost:3001`;

    await page.context().clearCookies();
    await loginWithToken(page, loginToken(testDB, state.slug, state.morganId), SUB);

    await page.goto(`${SUB}/admin/dashboard`);
    await page.waitForLoadState('networkidle');
    await expect(page.locator('body'), 'she reaches the dashboard')
      .not.toContainText('Internal Server Error');

    // The job she was invited for. Reaching the dashboard is access; being able
    // to start a program is the work.
    await page.goto(`${SUB}/program-creation`);
    await page.waitForLoadState('networkidle');
    await expect(page.locator('body')).not.toContainText('Internal Server Error');
    await expect(page.locator('form button[type="submit"], form input[type="submit"]').first(),
      'and the program-creation screen offers her a way in').toBeVisible({ timeout: 10000 });
  });
});
