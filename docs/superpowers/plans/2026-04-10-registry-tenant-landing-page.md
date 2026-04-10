# Registry Tenant Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the registry tenant's landing page at tinyartempire.com for Jordan (art teacher discovering the platform) using the vaporwave design system.

**Architecture:** Three deliverables: (1) rewrite the filesystem template using design system classes so new tenants start styled, (2) create Jordan's landing page as a DB-stored template for the registry tenant, (3) draft landing page copy via a specialized agent. The landing page uses the existing ProgramListing workflow step data but renders as a marketing page rather than a catalog.

**Tech Stack:** Mojolicious templates (Embedded Perl), CSS custom properties from theme.css/app.css, ProgramListing workflow step, DB-stored templates.

**Spec:** `docs/specs/registry-tenant-landing-page.md`

**Design system:** `docs/design-system.md`, `public/css/theme.css`, `public/css/app.css`

---

### Task 1: Rewrite filesystem template with design system classes

The current `templates/tenant-storefront/program-listing.html.ep` uses non-existent Tailwind classes. Rewrite it to use the vaporwave design system. This is the **initial version** for new tenants -- it shows a real program listing (sessions, prices, register buttons) using design system components.

**Files:**
- Modify: `templates/tenant-storefront/program-listing.html.ep`
- Modify: `t/controller/tenant-storefront.t`
- Modify: `t/css/style.t` (if element selectors need updating)
- Modify: `t/css/structure.t` (if element selectors need updating)
- Modify: `t/controller/ui-consistency-fix.t` (if element selectors need updating)

- [ ] **Step 1: Write a failing test for design system classes in the storefront**

Add a test to `t/controller/tenant-storefront.t` that verifies the storefront uses design system classes instead of Tailwind. Add after the existing tests:

```perl
# ============================================================
# Test 7: Storefront uses design system classes
# ============================================================
subtest 'storefront uses design system classes not Tailwind' => sub {
    $t->get_ok('/')
      ->status_is(200);

    # Design system classes present
    $t->element_exists('.landing-page', 'Uses landing-page container')
      ->element_exists('.landing-hero', 'Uses landing-hero section')
      ->element_exists('.landing-cta-button', 'Uses landing-cta-button for CTA');

    # Tailwind classes absent
    $t->content_unlike(qr/class="[^"]*bg-white/, 'No Tailwind bg-white class')
      ->content_unlike(qr/class="[^"]*text-gray/, 'No Tailwind text-gray class');
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/controller/tenant-storefront.t`
Expected: Test 7 FAILS -- current template uses Tailwind classes.

- [ ] **Step 3: Rewrite the filesystem template**

Rewrite `templates/tenant-storefront/program-listing.html.ep` using design system classes. This template is the initial version for **new tenants** -- it shows programs, sessions, pricing, and register/waitlist buttons. Key changes:

- Set `no_container => 1` and `enable_background_effects => 1` in stash
- Wrap everything in `<div class="landing-page">`
- Use `.landing-hero` for the header area with program name
- Use `.landing-feature-card` for session cards
- Use `.landing-cta-button` for register/waitlist buttons
- Use `.landing-features` / `.landing-features-grid` for the session grid
- Use design system tokens for all colors, spacing, typography
- Preserve the existing callcc form mechanism with `registration_workflow` metadata
- Preserve empty state rendering

```html
% layout 'default';
% title stash('page_title') || 'Programs';
% stash no_container => 1, enable_background_effects => 1;

% my $registration_workflow_default = 'summer-camp-registration';

<div class="landing-page">
  <!-- Navigation -->
  <nav class="landing-nav">
    <div class="landing-logo"><%%= title %></div>
  </nav>

  % if (@$programs) {
    % for my $prog (@$programs) {
      % my $project = $prog->{project};
      % my $program_type = $prog->{program_type};
      % my $reg_workflow = ($project->metadata || {})->{registration_workflow} || $registration_workflow_default;

      <!-- Hero: Program Name and Description -->
      <section class="landing-hero">
        <h1><%%= $project->name %></h1>
        % if ($project->notes) {
          <p class="landing-hero-subtitle"><%%= $project->notes %></p>
        % }
        % if ($program_type) {
          <p class="landing-trial-info"><%%= $program_type->name %></p>
        % }
      </section>

      <!-- Sessions -->
      <section class="landing-features">
        <div class="landing-features-container">
          <h2>Available Sessions</h2>
          <div class="landing-features-grid">
            % for my $sess_info (@{$prog->{sessions}}) {
              % my $session = $sess_info->{session};
              <article class="landing-feature-card">
                <h3 class="landing-feature-title"><%%= $session->name %></h3>
                <p class="landing-feature-description">
                  <%%= $session->start_date %> to <%%= $session->end_date %>
                </p>
                % if ($sess_info->{best_price}) {
                  <p class="landing-feature-subtitle">$<%%= $sess_info->{best_price} %></p>
                % }
                <div class="landing-cta-container">
                  % if ($sess_info->{is_full}) {
                    <p class="text-warning font-bold">Full</p>
                    <form method="POST"
                          action="/tenant-storefront/<%%= $run->id %>/callcc/<%%= $reg_workflow %>">
                      <input type="hidden" name="session_id" value="<%%= $session->id %>">
                      <input type="hidden" name="program_id" value="<%%= $project->id %>">
                      % if ($sess_info->{location_id}) {
                        <input type="hidden" name="location_id" value="<%%= $sess_info->{location_id} %>">
                      % }
                      <button type="submit" class="landing-cta-button">Join Waitlist</button>
                    </form>
                  % } else {
                    % if (defined $sess_info->{available_spots}) {
                      <p class="landing-feature-description">
                        <%%= $sess_info->{available_spots} %> spots left
                      </p>
                    % }
                    <form method="POST"
                          action="/tenant-storefront/<%%= $run->id %>/callcc/<%%= $reg_workflow %>">
                      <input type="hidden" name="session_id" value="<%%= $session->id %>">
                      <input type="hidden" name="program_id" value="<%%= $project->id %>">
                      % if ($sess_info->{location_id}) {
                        <input type="hidden" name="location_id" value="<%%= $sess_info->{location_id} %>">
                      % }
                      <button type="submit" class="landing-cta-button">Register</button>
                    </form>
                  % }
                </div>
              </article>
            % }
          </div>
        </div>
      </section>
    % }
  % } else {
    <section class="landing-hero">
      <h1>Coming Soon</h1>
      <p class="landing-hero-subtitle">No programs currently available. Check back soon!</p>
    </section>
  % }
</div>
```

- [ ] **Step 4: Update CSS tests that check for specific element selectors**

The tests in `t/css/style.t`, `t/css/structure.t`, and `t/controller/ui-consistency-fix.t` may need selector updates to match the new template. Run them and fix any failures caused by our template rewrite. These tests should check for design system classes that now exist.

- [ ] **Step 5: Run all affected tests**

Run: `carton exec prove -l t/controller/tenant-storefront.t t/controller/landing-page-cta.t t/controller/ui-consistency-fix.t t/css/style.t t/css/structure.t t/e2e/tenant-onboarding.t`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add templates/tenant-storefront/program-listing.html.ep t/controller/tenant-storefront.t t/css/style.t t/css/structure.t t/controller/ui-consistency-fix.t t/controller/landing-page-cta.t t/e2e/tenant-onboarding.t
git commit -m "Rewrite storefront template to use vaporwave design system classes"
```

### Task 2: Draft landing page copy

Delegate copywriting to a specialized agent. The copy follows Simon Sinek's "Start with Why" framework. Voice: direct, practical, warm.

**Files:**
- Create: `docs/copy/registry-landing-page.md` (copy document for review)

- [ ] **Step 1: Dispatch copywriting agent**

Spin up a subagent with this brief:

> Write landing page copy for TinyArtEmpire.com targeting Jordan -- an art teacher who teaches after-school art programs and wants to spend less time on business admin and more time in the studio. She found us via referral.
>
> Structure (Simon Sinek's "Start with Why"):
>
> 1. **Hero headline** -- connect her identity as an artist to our promise. One line.
> 2. **Hero subtitle** -- one sentence bridging her pain to our solution.
> 3. **6 problem cards** -- each has a headline (5-8 words) and one sentence (under 20 words). Problems in order she'd encounter them:
>    - Getting found / generating registrations (school relationships, parent pipeline)
>    - Getting paid reliably (online payments, no check-chasing)
>    - Managing the chaos (scheduling, attendance, waitlists, multi-child families)
>    - Keeping in touch (parent communication, notifications)
>    - Knowing your numbers (revenue tracking, throughput, plain language)
>    - Growing when you're ready (staff management at scale)
> 4. **Alignment statement** -- "Free to start. We only earn when you do." Plus one sentence explaining the 2.5% revenue share as proof of shared incentives.
> 5. **CTA button text** -- "Get Started"
>
> Voice: direct, practical, warm. Not salesy. Not clever. She's busy -- respect her time. She's an artist, not a business school graduate -- no jargon.
>
> Output: structured markdown with each section clearly labeled. Include 2-3 alternatives for the hero headline.

- [ ] **Step 2: Review copy and pick the best headline variant**

Review the agent's output with perigrin. Save final copy to `docs/copy/registry-landing-page.md`.

- [ ] **Step 3: Commit**

```bash
git add docs/copy/registry-landing-page.md
git commit -m "Add landing page copy for registry tenant"
```

### Task 3: Create Jordan's landing page as registry DB template

Build the registry tenant's customized template -- the marketing landing page Jordan sees at tinyartempire.com. This gets inserted into the registry schema's `templates` table via a sqitch migration.

**Files:**
- Create: `sql/deploy/registry-landing-page-template.sql`
- Create: `sql/revert/registry-landing-page-template.sql`
- Create: `sql/verify/registry-landing-page-template.sql`
- Modify: `sql/sqitch.plan`
- Create: `t/controller/registry-landing-page.t`

- [ ] **Step 1: Write a failing test for the registry landing page**

Create `t/controller/registry-landing-page.t` that verifies the registry tenant's storefront renders as a marketing landing page with hero, problem cards, alignment section, and CTA.

```perl
#!/usr/bin/env perl
# ABOUTME: Tests the registry tenant's customized landing page for Jordan's journey.
# ABOUTME: Verifies hero, problem cards, alignment section, and callcc CTA render correctly.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::Template;
use Mojo::Home;
use Mojo::File;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import all workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

# Seed registry-like data: project with registration_workflow metadata
my $location = $dao->create(Location => {
    name => 'Online', slug => 'online-test',
    address_info => { type => 'virtual' }, metadata => {},
});
my $teacher = $dao->create(User => { username => 'system-test', user_type => 'staff' });
my $project = $dao->create(Project => {
    name => 'Tiny Art Empire', slug => 'tiny-art-empire-test',
    notes => 'Platform for art educators',
    metadata => { registration_workflow => 'tenant-signup' },
});
my $session = $dao->create(Session => {
    name => 'Get Started', slug => 'get-started-test',
    start_date => '2026-01-01', end_date => '2036-01-01',
    status => 'published', capacity => 999999, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-01-01 00:00:00', duration => 0,
    location_id => $location->id, project_id => $project->id,
    teacher_id => $teacher->id, capacity => 999999, metadata => {},
});
$session->add_events($dao->db, $event->id);

# Load the registry landing page template into the DB
# (This simulates what the sqitch migration does)
my $template_content = Mojo::File->new('docs/copy/registry-landing-page-template.html.ep')->slurp;
$dao->db->update('templates',
    { content => $template_content },
    { name => 'tenant-storefront/program-listing' },
);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ============================================================
# Test 1: Landing page renders with vaporwave design system
# ============================================================
subtest 'landing page renders with vaporwave design system' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-page', 'Landing page container present')
      ->element_exists('.landing-hero', 'Hero section present')
      ->element_exists('.landing-cta-button', 'CTA button present');

    # No Tailwind classes
    $t->content_unlike(qr/class="[^"]*bg-white/, 'No Tailwind classes');
};

# ============================================================
# Test 2: Hero section has headline and subtitle
# ============================================================
subtest 'hero section has headline and subtitle' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-hero h1', 'Hero headline exists')
      ->element_exists('.landing-hero-subtitle', 'Hero subtitle exists');

    # CTA links to tenant-signup
    my $dom = $t->tx->res->dom;
    my $cta = $dom->at('form[action*="callcc"]');
    ok $cta, 'callcc form found';
    if ($cta) {
        like $cta->attr('action'), qr{/callcc/tenant-signup},
            'CTA targets tenant-signup workflow';
    }
};

# ============================================================
# Test 3: Problem cards section exists
# ============================================================
subtest 'problem cards section exists' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-features', 'Features section present')
      ->element_exists('.landing-feature-card', 'At least one feature card present');

    # Count cards -- should be 6
    my $dom = $t->tx->res->dom;
    my $cards = $dom->find('.landing-feature-card');
    is $cards->size, 6, 'Six problem cards rendered';
};

# ============================================================
# Test 4: Alignment section with pricing
# ============================================================
subtest 'alignment section with pricing' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->content_like(qr/2\.5%/, 'Revenue share percentage visible')
      ->content_like(qr/Free to start/i, 'Free to start messaging visible');
};

# ============================================================
# Test 5: CTA button says Get Started
# ============================================================
subtest 'CTA button text' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->text_like('.landing-cta-button', qr/Get Started/i, 'CTA says Get Started');
};

# ============================================================
# Test 6: No raw session data exposed
# ============================================================
subtest 'no raw session data on landing page' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->content_unlike(qr/999999 spots left/, 'No raw capacity shown')
      ->content_unlike(qr/2036-01-01/, 'No evergreen end date shown');
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/controller/registry-landing-page.t`
Expected: FAILS -- the template file doesn't exist yet and the DB template hasn't been customized.

- [ ] **Step 3: Create the landing page template file**

Create `docs/copy/registry-landing-page-template.html.ep` -- the actual HTML template that will be stored in the registry tenant's DB. This uses copy from Task 2 and design system classes.

The template receives `$programs` and `$run` from ProgramListing but renders marketing content instead of raw session data. It only uses the data for the callcc form action.

```html
%% layout 'default';
%% title 'Tiny Art Empire';
%% stash no_container => 1, enable_background_effects => 1;

%% # Extract data for callcc form
%% my $prog = $programs->[0] || {};
%% my $project = $prog->{project};
%% my $sess_info = ($prog->{sessions} || [])->[0] || {};
%% my $session = $sess_info->{session};
%% my $reg_workflow = ($project && $project->metadata || {})->{registration_workflow} || 'tenant-signup';

<div class="landing-page">
  <nav class="landing-nav">
    <div class="landing-logo">Tiny Art Empire</div>
  </nav>

  <!-- Hero: The Why -->
  <section class="landing-hero">
    <h1>[HERO HEADLINE FROM COPY]</h1>
    <p class="landing-hero-subtitle">[HERO SUBTITLE FROM COPY]</p>
    <div class="landing-cta-container">
      %% if ($project && $session) {
        <form method="POST"
              action="/tenant-storefront/<%%== $run->id %%>/callcc/<%%== $reg_workflow %%>">
          <input type="hidden" name="session_id" value="<%%== $session->id %%>">
          <input type="hidden" name="program_id" value="<%%== $project->id %%>">
          <button type="submit" class="landing-cta-button">Get Started</button>
        </form>
      %% } else {
        <a href="<%%== url_for('workflow_start', workflow => 'tenant-signup') %%>" class="landing-cta-button">
          Get Started
        </a>
      %% }
    </div>
  </section>

  <!-- Problem Cards: The How -->
  <section class="landing-features">
    <div class="landing-features-container">
      <h2>[SECTION HEADING FROM COPY]</h2>
      <div class="landing-features-grid">
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">[CARD 1 HEADLINE]</h3>
          <p class="landing-feature-description">[CARD 1 DESCRIPTION]</p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">[CARD 2 HEADLINE]</h3>
          <p class="landing-feature-description">[CARD 2 DESCRIPTION]</p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">[CARD 3 HEADLINE]</h3>
          <p class="landing-feature-description">[CARD 3 DESCRIPTION]</p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">[CARD 4 HEADLINE]</h3>
          <p class="landing-feature-description">[CARD 4 DESCRIPTION]</p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">[CARD 5 HEADLINE]</h3>
          <p class="landing-feature-description">[CARD 5 DESCRIPTION]</p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">[CARD 6 HEADLINE]</h3>
          <p class="landing-feature-description">[CARD 6 DESCRIPTION]</p>
        </article>
      </div>
    </div>
  </section>

  <!-- Alignment: The Trust -->
  <section class="landing-features">
    <div class="landing-features-container" style="text-align: center;">
      <h2>Free to Start</h2>
      <p class="landing-hero-subtitle">
        [ALIGNMENT COPY -- 2.5% revenue share as proof of shared incentives]
      </p>
      <div class="landing-cta-container">
        %% if ($project && $session) {
          <form method="POST"
                action="/tenant-storefront/<%%== $run->id %%>/callcc/<%%== $reg_workflow %%>">
            <input type="hidden" name="session_id" value="<%%== $session->id %%>">
            <input type="hidden" name="program_id" value="<%%== $project->id %%>">
            <button type="submit" class="landing-cta-button">Get Started</button>
          </form>
        %% } else {
          <a href="<%%== url_for('workflow_start', workflow => 'tenant-signup') %%>" class="landing-cta-button">
            Get Started
          </a>
        %% }
      </div>
    </div>
  </section>

  <footer style="text-align: center; padding: var(--space-8); color: var(--landing-text-secondary); font-size: var(--font-size-sm);">
    <p>A <strong>Tamarou</strong> &amp; <strong>Super Awesome Cool Pottery</strong> project</p>
  </footer>
</div>
```

**Note:** The `[PLACEHOLDER]` text will be replaced with actual copy from Task 2. The template structure and design system classes are the implementation concern here.

- [ ] **Step 4: Create the sqitch migration to load the template into the registry DB**

Create `sql/deploy/registry-landing-page-template.sql`:

```sql
BEGIN;
SET search_path TO registry, public;

UPDATE templates
SET content = $TEMPLATE_CONTENT$
[full template content here]
$TEMPLATE_CONTENT$,
    updated_at = now()
WHERE name = 'tenant-storefront/program-listing';

COMMIT;
```

Create `sql/revert/registry-landing-page-template.sql` that resets to the filesystem version.

Create `sql/verify/registry-landing-page-template.sql` that checks the template was updated.

Add to `sql/sqitch.plan`:
```
registry-landing-page-template [seed-registry-storefront] 2026-04-10T00:00:00Z Chris Prather <chris.prather@tamarou.com> # Customize registry tenant landing page for Jordan's journey
```

- [ ] **Step 5: Run all tests**

Run: `carton exec prove -lv t/controller/registry-landing-page.t`
Expected: ALL PASS

Run: `carton exec prove -l t/controller/tenant-storefront.t t/e2e/tenant-onboarding.t t/database/migration-verification.t`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add docs/copy/registry-landing-page-template.html.ep sql/deploy/registry-landing-page-template.sql sql/revert/registry-landing-page-template.sql sql/verify/registry-landing-page-template.sql sql/sqitch.plan t/controller/registry-landing-page.t
git commit -m "Add registry tenant landing page for Jordan's user journey"
```

### Task 4: Fill in copy and finalize

Replace placeholder text with the approved copy from Task 2.

**Files:**
- Modify: `docs/copy/registry-landing-page-template.html.ep`
- Modify: `sql/deploy/registry-landing-page-template.sql`

- [ ] **Step 1: Replace all `[PLACEHOLDER]` text with final copy**

Update both the template file and the sqitch migration with the approved copy from `docs/copy/registry-landing-page.md`.

- [ ] **Step 2: Run the full test suite for affected files**

Run: `carton exec prove -l t/controller/registry-landing-page.t t/controller/tenant-storefront.t t/controller/landing-page-cta.t t/css/style.t t/css/structure.t t/e2e/tenant-onboarding.t t/database/migration-verification.t`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
git add docs/copy/registry-landing-page-template.html.ep sql/deploy/registry-landing-page-template.sql
git commit -m "Fill in landing page copy for registry tenant"
```

### Task 5: Final verification

- [ ] **Step 1: Run the full test suite**

Run: `carton exec prove -lr t/`
Expected: ALL PASS (except known pre-existing failures in `t/dao/waitlist.t` and `t/integration/stripe-webhook-integration.t`)

- [ ] **Step 2: Deploy sqitch migration locally and verify**

```bash
carton exec sqitch deploy
carton exec sqitch verify
```

- [ ] **Step 3: Start dev server and visually verify**

```bash
carton exec morbo ./registry
```

Visit `http://localhost:3000` and verify:
- Vaporwave styling renders (grid background, floating shapes, gradient text)
- Hero section visible with headline and subtitle
- 6 problem cards in a responsive grid
- Alignment section with pricing
- "Get Started" CTA button works (redirects to tenant-signup)
- Mobile responsive (resize browser)
- Dark/light theme toggle works

- [ ] **Step 4: Commit any final fixes**
