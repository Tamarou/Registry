-- Deploy registry-landing-page-template
-- Customize the registry tenant's storefront template for Jordan's user journey.
-- This replaces the generic program listing with a marketing landing page.

BEGIN;

SET search_path TO registry, public;

INSERT INTO templates (name, slug, content, metadata, notes)
VALUES (
    'tenant-storefront/program-listing',
    'tenant-storefront-program-listing',
    $TMPL$% layout 'default';
% title 'Tiny Art Empire';
% stash no_container => 1, enable_background_effects => 1;

% # Extract data for callcc form
% my $prog = $programs->[0] || {};
% my $project = $prog->{project};
% my $sess_info = ($prog->{sessions} || [])->[0] || {};
% my $session = $sess_info->{session};
% my $reg_workflow = ($project && $project->metadata || {})->{registration_workflow} || 'tenant-signup';

<div class="landing-page">
  <nav class="landing-nav">
    <div class="landing-logo">Tiny Art Empire</div>
  </nav>

  <!-- Hero: The Why -->
  <section class="landing-hero">
    <h1>Your art deserves a real business.</h1>
    <p class="landing-hero-subtitle">
      Everything you need to fill classes, get paid, and stay organized
      -- so you can get back to making art.
    </p>
    <div class="landing-cta-container">
      % if ($project && $session) {
        <form method="POST"
              action="/tenant-storefront/<%= $run->id %>/callcc/<%= $reg_workflow %>">
          <input type="hidden" name="session_id" value="<%= $session->id %>">
          <input type="hidden" name="program_id" value="<%= $project->id %>">
          <button type="submit" class="landing-cta-button">Get Started</button>
        </form>
      % } else {
        <a href="<%= url_for('workflow_start', workflow => 'tenant-signup') %>" class="landing-cta-button">
          Get Started
        </a>
      % }
    </div>
  </section>

  <!-- Problem Cards: The How -->
  <section class="landing-features">
    <div class="landing-features-container">
      <h2>Less paperwork. More studio time.</h2>
      <div class="landing-features-grid">
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">Fill your classes without the hustle</h3>
          <p class="landing-feature-description">
            Parents find your programs and register online -- no back-and-forth
            emails or paper forms.
          </p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">Get paid before class starts</h3>
          <p class="landing-feature-description">
            Online payments at registration. No chasing checks, no awkward reminders.
          </p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">One place for all of it</h3>
          <p class="landing-feature-description">
            Scheduling, attendance, waitlists, and families with three kids -- handled.
          </p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">Keep parents in the loop</h3>
          <p class="landing-feature-description">
            Automatic updates and notifications so you're not writing the same
            email twelve times.
          </p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">See how your business is doing</h3>
          <p class="landing-feature-description">
            Plain-English reports on revenue, enrollment, and trends.
            No spreadsheet required.
          </p>
        </article>
        <article class="landing-feature-card">
          <h3 class="landing-feature-title">Grow when you're ready</h3>
          <p class="landing-feature-description">
            Add instructors, locations, and programs without adding chaos.
          </p>
        </article>
      </div>
    </div>
  </section>

  <!-- Alignment: The Trust -->
  <section class="landing-features">
    <div class="landing-features-container" style="text-align: center;">
      <h2>Free to Start</h2>
      <p class="landing-hero-subtitle">
        We take 2.5% of what you earn through the platform. That's it -- no
        monthly fees, no setup costs. We only make money when you do, so our
        entire job is helping you succeed.
      </p>
      <div class="landing-cta-container">
        % if ($project && $session) {
          <form method="POST"
                action="/tenant-storefront/<%= $run->id %>/callcc/<%= $reg_workflow %>">
            <input type="hidden" name="session_id" value="<%= $session->id %>">
            <input type="hidden" name="program_id" value="<%= $project->id %>">
            <button type="submit" class="landing-cta-button">Get Started</button>
          </form>
        % } else {
          <a href="<%= url_for('workflow_start', workflow => 'tenant-signup') %>" class="landing-cta-button">
            Get Started
          </a>
        % }
      </div>
    </div>
  </section>

  <footer style="text-align: center; padding: var(--space-8); color: var(--landing-text-secondary); font-size: var(--font-size-sm);">
    <p>A <strong>Tamarou</strong> &amp; <strong>Super Awesome Cool Pottery</strong> project</p>
  </footer>
</div>$TMPL$,
    '{}'::jsonb,
    'Registry tenant landing page for Jordan (art teacher) user journey'
)
ON CONFLICT (name) DO UPDATE SET
    content = EXCLUDED.content,
    notes = EXCLUDED.notes,
    updated_at = now();

COMMIT;
