# Tenant Storefront Workflow Specification

## Overview

Replace the hardcoded `Landing` controller and bespoke `Schools` controller
with a workflow-driven tenant storefront. Every tenant -- including Tiny Art
Empire itself -- has a `tenant-storefront` workflow whose first step renders
that tenant's public landing page. The root URL `/` dispatches to this
workflow via the existing Workflows controller.

## Architectural Principles

1. **Every user journey is a workflow.** No bespoke controllers for
   public-facing pages. The Workflows controller is the only dispatcher.

2. **Workflows are the sales funnel.** The storefront is the top of a
   `callcc` chain. When a visitor clicks "Register", the storefront workflow
   starts a continuation into the appropriate registration workflow. When
   registration completes, control returns to the storefront.

3. **Schema scoping handles multi-tenancy.** The same workflow step class,
   same query config, same template can serve different tenants because the
   DAO is scoped to the tenant's schema. Different schemas contain different
   data.

4. **Step behavior is data-driven.** The `ProgramListing` step class reads
   configuration from the workflow YAML (step metadata/config) to determine
   what data to load and how to present it. No business logic is hardcoded
   for a specific tenant.

## Prerequisite: Workflow Engine Fixes

Three limitations in the workflow engine must be fixed before the storefront
can work. These fixes are backwards-compatible and also resolve pre-existing
bugs documented in Phase 1.

### Fix 1: GET auto-creates run and renders step directly

**Problem:** The `workflows#index` method renders a `{workflow}/index`
template but does not create a WorkflowRun. Without a run, the template has
no run ID for `callcc` buttons. The current flow requires a user to POST to
`start_workflow` first, creating an unnecessary two-page redirect.

**Fix:** Add a `show_or_start` method (or modify `index`) that
find-or-creates a run and renders the first step's template directly:

```perl
method index() {
    my $dao = $self->app->dao;
    my $workflow = $self->workflow();

    # Find existing incomplete run for this session, or create a new one
    my $run = $self->_find_or_create_run($workflow);

    my $step = $run->latest_step($dao->db) || $workflow->first_step($dao->db);

    # Render the step template directly (not a separate index template)
    my $template_data = $step->prepare_template_data($dao->db, $run);

    return $self->render(
        template => $self->param('workflow') . '/' . $step->slug,
        workflow => $self->param('workflow'),
        step     => $step->slug,
        action   => $self->url_for('workflow_process_step',
            workflow => $self->param('workflow'),
            run => $run->id,
            step => $step->slug),
        run      => $run,
        data_json => Mojo::JSON::encode_json($run->data || {}),
        errors_json => Mojo::JSON::encode_json([]),
        %$template_data,
    );
}

method _find_or_create_run($workflow) {
    my $dao = $self->app->dao;

    # Check session for an existing run ID for this workflow
    my $run_id = $self->session("workflow_run_${\$workflow->slug}");
    if ($run_id) {
        my ($run) = $dao->find(WorkflowRun => { id => $run_id });
        return $run if $run && !$run->completed($dao->db);
    }

    # Create a new run
    my $run = $self->new_run($workflow);
    $self->session("workflow_run_${\$workflow->slug}" => $run->id);
    return $run;
}
```

This eliminates the need for a separate `index.html.ep` template per
workflow. The GET renders the first step's template with a live run.

**Scope:** `lib/Registry/Controller/Workflows.pm` -- modify `index` method
(~25 lines).

**Backwards compatibility:** Existing workflows that have `index.html.ep`
templates can keep them via a fallback: if a `{workflow}/index.html.ep`
exists, use the old behavior; otherwise, use the new auto-run behavior. Or
simply update existing index templates to be step templates.

### Fix 2: Support `stay` semantics in the controller

**Problem:** When a step returns `{stay => 1}`, the controller ignores it
and advances to `next_step`. This breaks any step that needs to handle
multiple form submissions without advancing (e.g., add_child in
SelectChildren, filter submission in ProgramListing).

**Fix:** Check for `stay` in `process_workflow_run_step` before advancing:

```perl
method process_workflow_run_step {
    ...
    my $result = $run->process( $dao->db, $step, $data );

    # Check for validation errors
    my $validation_errors = $result->{_validation_errors} || $result->{errors};
    if ($validation_errors) {
        $self->flash(validation_errors => $validation_errors);
        return $self->redirect_to($self->url_for);
    }

    # Check for stay -- step wants to remain on the current page
    if ($result->{stay}) {
        return $self->redirect_to($self->url_for);
    }

    # if we're still not done, redirect to the next step
    ...
}
```

Also add `stay` to the `@TRANSIENT_KEYS` list in `WorkflowRun::process` so
it is not persisted in the run's JSONB data:

```perl
my @TRANSIENT_KEYS = qw(
    next_step errors data _validation_errors stay
    retry_count retry_delay retry_exceeded should_retry
);
```

**Scope:** `lib/Registry/Controller/Workflows.pm` (~5 lines),
`lib/Registry/DAO/WorkflowRun.pm` (1 line).

**Backwards compatibility:** Fully backwards-compatible. No existing
workflow steps return `{stay => 1}` through the controller path (the bug was
worked around in tests by pre-creating data via the DAO). This fix also
unblocks the SelectChildren add_child flow documented as broken in Phase 1.

### Fix 3: Continuation return to a completed single-step workflow

**Problem:** When a `callcc` continuation completes and control returns to
the parent workflow, the controller calls `$run->next_step()` to find where
to redirect. For a single-step workflow that has already processed its only
step, `next_step` returns undef and the controller either dies or renders
"DONE" -- instead of showing the storefront again.

**Fix:** When returning from a continuation to a completed parent workflow,
re-render the parent's latest step instead of looking for a next step:

```perl
# In process_workflow_run_step, after the continuation return block:
if ( $run->has_continuation ) {
    my ($parent_run) = $run->continuation( $dao->db );
    my ($parent_workflow) = $parent_run->workflow( $dao->db );
    my ($parent_step) = $parent_run->next_step( $dao->db );

    # If parent has a next step, redirect there
    if ($parent_step) {
        return $self->redirect_to(...);
    }

    # Parent workflow is complete (single-step) -- re-render latest step
    my $latest = $parent_run->latest_step( $dao->db );
    return $self->redirect_to(
        $self->url_for(
            'workflow_step',
            workflow => $parent_workflow->slug,
            run      => $parent_run->id,
            step     => $latest->slug,
        )
    );
}
```

**Scope:** `lib/Registry/Controller/Workflows.pm` (~10 lines in the
continuation handling block).

**Backwards compatibility:** Only affects continuation returns to
single-step workflows, which don't exist yet. No impact on existing
multi-step workflows.

## What Changes

### Remove

- `lib/Registry/Controller/Landing.pm` -- hardcoded root route handler
- `lib/Registry/Controller/Schools.pm` -- bespoke program listing controller
- `templates/index.html.ep` -- static marketing page (replaced by workflow
  template)
- `templates/schools/show.html.ep` -- bespoke school page
- `templates/schools/_programs.html.ep` -- bespoke programs partial
- Route: `$self->routes->get('/')->to('landing#root')`
- Route: `$self->routes->get('/school/:slug')->to('schools#show')`

### Add

- `lib/Registry/DAO/WorkflowSteps/ProgramListing.pm` -- step class for
  loading and presenting available programs/sessions
- `workflows/tenant-storefront.yaml` -- workflow definition
- `templates/tenant-storefront/program-listing.html.ep` -- program listing
  template
- `templates/tenant-storefront/marketing.html.ep` -- Tiny Art Empire
  marketing template (for registry tenant)
- Route: root `/` dispatches to Workflows controller with
  `workflow => 'tenant-storefront'`

### Modify

- `lib/Registry/Controller/Workflows.pm` -- engine fixes (stay, auto-run,
  continuation return)
- `lib/Registry/DAO/WorkflowRun.pm` -- add `stay` to transient keys
- `lib/Registry.pm` -- replace root route, remove `/school/:slug` route

## Routing

The root route changes from a bespoke controller to the Workflows controller:

```perl
# Before
$self->routes->get('/')->to('landing#root')->name('root_handler');

# After
my $root = $self->routes;
$root->get('/')->to('workflows#index', workflow => 'tenant-storefront')->name('root_handler');
$root->post('/')->to('workflows#start_workflow', workflow => 'tenant-storefront');
```

The `/:workflow` catch-all continues to handle all other workflows. The root
route is declared first (before the catch-all) and hardcodes the workflow
slug to `tenant-storefront`.

Note: The `callcc` URLs use the full workflow slug path
(`/tenant-storefront/{run_id}/callcc/{target}`), which is handled by the
existing `/:workflow/:run/callcc/:target` catch-all route. The root route
only handles GET/POST to `/` itself.

## Workflow Definition

```yaml
name: Tenant Storefront
slug: tenant-storefront
description: Public-facing landing page and program listing for a tenant
first_step: program-listing
steps:
  - slug: program-listing
    description: Browse Available Programs
    template: tenant-storefront/program-listing
    class: Registry::DAO::WorkflowSteps::ProgramListing
```

This is a single-step workflow. The step renders the program listing. The
"Register" buttons are `callcc` links that start continuation workflows
(e.g., `summer-camp-registration`). When a registration workflow completes,
the continuation returns to this workflow and re-renders the program listing.

For the `registry` tenant (Tiny Art Empire itself), a separate YAML uses a
different template:

```yaml
name: Tiny Art Empire
slug: tenant-storefront
description: Tiny Art Empire platform marketing page
first_step: program-listing
steps:
  - slug: program-listing
    description: Platform Overview
    template: tenant-storefront/marketing
    class: Registry::DAO::WorkflowSteps::ProgramListing
```

Same step class, different template. The registry schema has one "program"
(the platform itself), and the marketing template renders the hero, pricing
tiers, and signup CTA.

## Step Class: ProgramListing

### File

`lib/Registry/DAO/WorkflowSteps/ProgramListing.pm`

### Responsibilities

- Load published programs (projects) for the current tenant
- For each program, load published sessions with:
  - Dates (start_date, end_date)
  - Capacity and availability (enrolled count, spots remaining)
  - Pricing (from PricingPlan, including early-bird if applicable)
  - Waitlist status (is full, has waitlist)
  - Program type metadata (age range, grade range, description)
- Apply filters from query parameters (age, date, program type)
- Return all data via `prepare_template_data` for the template

### Key Methods

```perl
method prepare_template_data ($db, $run) {
    # Load programs and sessions for the current tenant schema
    # The $db handle is already scoped to the tenant's schema
    # Apply any filters from $run->data or step config
    # Return hashref with programs, sessions, filters, run object, etc.
}

method process ($db, $form_data) {
    # Handle filter submissions -- store filter values and stay on page
    if ($form_data->{action} && $form_data->{action} eq 'filter') {
        # Store filter values in run data for prepare_template_data
        return { stay => 1 };
    }
    # Default: stay on the listing page
    return { stay => 1 };
}
```

### Data Shape Returned by prepare_template_data

```perl
{
    programs => [
        {
            project      => $project_obj,
            program_type => $program_type_obj,  # may be undef
            sessions     => [
                {
                    session         => $session_obj,
                    enrolled_count  => 14,
                    capacity        => 16,
                    available_spots => 2,
                    is_full         => 0,
                    has_waitlist    => 0,
                    pricing_plans   => [ $plan1, $plan2 ],
                    best_price      => 300.00,
                },
                # ...
            ],
        },
        # ...
    ],
    filters => {
        program_type => $selected_type,
        age_range    => $selected_age,
        date_range   => $selected_dates,
    },
    available_filters => {
        program_types => [ @types_with_sessions ],
    },
    run => $run,  # needed for callcc URLs in template
}
```

### Data Loading Logic

The data loading logic currently lives in `Schools#show`. It should be
migrated into the step class. The key queries:

1. **Programs**: `SELECT * FROM projects WHERE ...` -- all projects that
   have at least one published session with future events.

2. **Sessions per program**: Sessions joined with events, filtered by
   `status = 'published'` and `end_date >= CURRENT_DATE`.

3. **Enrollment counts**: `Enrollment->count_for_session($db, $session_id)`
   for availability display.

4. **Pricing**: `PricingPlan` records for each session, including early-bird
   detection.

5. **Program type metadata**: `ProgramType` record for age range, grade
   range, description.

The queries run against the tenant's schema (set by the DAO), so they
automatically return only that tenant's data.

### Future: Config-Driven Queries

The step currently hardcodes the query logic for program/session/pricing
loading. In the future, the step metadata in the workflow YAML could contain
a declarative query spec (SQL::Abstract-compatible data structure) that the
step class interprets. This allows tenants to customize what data their
storefront displays without changing code.

For now, the hardcoded logic covers all Tiny Art Empire tenant needs.

## Template: tenant-storefront/program-listing

### Requirements

The template renders a public-facing page with:

1. **Program cards** -- one card per program (project), showing:
   - Program name and description
   - Program type badge (e.g., "Summer Camp", "After School")
   - Age range / grade range
   - Number of available sessions

2. **Session details within each card** -- for each session:
   - Session name and dates
   - Price (best available)
   - Availability indicator (spots left, filling up, full, waitlist)
   - **Register button** -- a `callcc` form that continues into the
     registration workflow:
     ```html
     <form method="POST"
           action="/tenant-storefront/<%= $run->id %>/callcc/summer-camp-registration">
         <input type="hidden" name="session_id" value="<%= $session->id %>">
         <input type="hidden" name="program_id" value="<%= $project->id %>">
         <input type="hidden" name="location_id" value="<%= $location->id %>">
         <button type="submit">Register</button>
     </form>
     ```
   - **Join Waitlist button** for full sessions (same `callcc` mechanism)

3. **Filters** (optional, HTMX-driven):
   - Program type dropdown
   - Age range selector
   - Date range picker
   - Filters submit via HTMX to reload the program listing partial,
     or via POST with `action=filter` which uses the `stay` semantics

4. **Layout**: Uses `layout 'default'` (not `layout 'workflow'`) since this
   is a public-facing page, not a multi-step form.

### callcc Target Resolution

The registration workflow slug for each program is determined by the
program's `program_type_slug`. The mapping:

- `summer-camp` -> `summer-camp-registration`
- `afterschool` -> `afterschool-registration` (future)
- Default -> `summer-camp-registration` (for now)

This mapping lives in the step's `prepare_template_data` return value as
part of each program's data. The template reads it; no separate lookup.

## Migration Path

### Phase 0: Workflow Engine Fixes

1. Fix `stay` semantics in controller + add to transient keys
2. Add `_find_or_create_run` and update `index` to auto-create runs
3. Fix continuation return to completed single-step workflows
4. Write tests for each fix
5. Verify all existing tests still pass

### Phase 1: Ship for Super Awesome Cool Pottery

1. Create `ProgramListing` step class with hardcoded query logic (migrated
   from Schools#show)
2. Create `tenant-storefront/program-listing.html.ep` template (adapted
   from schools/show and schools/_programs)
3. Create `tenant-storefront.yaml` workflow
4. Change root route to dispatch to `tenant-storefront` workflow
5. Import the workflow for all existing tenant schemas
6. Remove `Landing` controller, `Schools` controller, and old templates
7. Remove `/school/:slug` route (no intermediate redirect state)

### Phase 2: Config-Driven (Future)

1. Add step metadata schema for query configuration
2. Build admin workflow for tenants to customize their storefront
3. Support SQL::Abstract query specs in step config

## Data Flow

```
Browser hits /
  -> Route resolves to Workflows#index with workflow='tenant-storefront'
  -> index calls _find_or_create_run (checks session, creates if needed)
  -> ProgramListing.prepare_template_data loads programs/sessions from tenant schema
  -> Renders tenant-storefront/program-listing template with run ID
  -> Template renders program cards with callcc Register buttons

Parent clicks Register on "Week 1 - Jun 1-5"
  -> POST /tenant-storefront/{run_id}/callcc/summer-camp-registration
  -> Workflows#start_continuation creates a new run for summer-camp-registration
  -> Registration workflow proceeds (account-check -> select-children -> ... -> complete)
  -> On completion, continuation returns to tenant-storefront
  -> Controller detects parent is complete single-step, re-renders latest step
  -> Parent sees program listing again, can register for another program
```

## Error Handling

- **No published sessions**: Template shows a message like "No programs
  currently available. Check back soon!" instead of an empty page.
- **Tenant not found**: Existing tenant resolution returns 'registry' as
  default, which shows the Tiny Art Empire marketing page.
- **Invalid filter values**: Ignored (treated as unfiltered). No 400 errors
  for bad query params on a public page.
- **callcc to nonexistent workflow**: The Workflows controller's
  `start_continuation` method will fail to find the workflow. This should
  render a user-friendly error, not a 500. Add error handling if not present.
- **Stale run ID in session**: If a run referenced by the session no longer
  exists (DB cleanup, schema migration), `_find_or_create_run` falls through
  to creating a new run.

## Testing Plan

### Phase 0: Engine Fix Tests

**File:** `t/controller/workflow-engine-fixes.t`

1. **Stay semantics**: POST to a step that returns `{stay => 1}` redirects
   back to the same step, not the next step. Verify with a two-step
   workflow where step 1 returns stay.

2. **Stay with single-step workflow**: POST to the only step in a
   single-step workflow with `{stay => 1}` does NOT mark the workflow as
   complete. Verify `completed()` returns false.

3. **Auto-run on GET**: GET to a workflow URL creates a run if none exists,
   renders the first step template with run data. Verify run exists in DB.

4. **Run reuse**: GET to the same workflow URL twice returns the same run
   (from session). Verify run ID is stable.

5. **Continuation return to single-step**: Complete a child workflow that
   has a continuation to a single-step parent. Verify redirect goes to the
   parent's latest step, not "DONE".

6. **SelectChildren add_child now works**: POST add_child to
   select-children step redirects back to select-children (not camper-info).
   This validates the stay fix against the known Phase 1 bug.

### Phase 1: Storefront Tests

**File:** `t/controller/tenant-storefront.t`

1. **GET / returns 200 with program listing**
   - Create a tenant with programs and sessions
   - GET `/` -> 200
   - Response contains program names and session names
   - Response contains "Register" buttons with callcc URLs

2. **Programs from different tenants are isolated**
   - Create two tenants with different programs
   - GET `/` with tenant A context -> shows only tenant A's programs
   - GET `/` with tenant B context -> shows only tenant B's programs

3. **Only published sessions with future dates shown**
   - Create sessions with status=draft and status=published
   - Create sessions with past end_date and future end_date
   - GET `/` -> only published future sessions appear

4. **Availability display correct**
   - Create session with capacity 16 and 14 enrollments
   - GET `/` -> shows "2 spots left" or equivalent

5. **Full session shows waitlist option**
   - Create session at capacity
   - GET `/` -> shows "Join Waitlist" instead of "Register"

6. **Filters narrow results**
   - Create sessions of different program types
   - POST with action=filter and program_type=summer-camp -> stays on page,
     shows only camp sessions

7. **callcc Register button creates continuation**
   - POST `/tenant-storefront/{run_id}/callcc/summer-camp-registration`
   - -> 302 redirect to registration workflow
   - Workflow run has continuation_id set

8. **Full callcc round-trip**: storefront -> registration -> return
   - Start at storefront, click Register (callcc)
   - Complete registration workflow
   - Verify return to storefront program listing page

9. **No programs shows empty state**
   - Tenant with no published sessions
   - GET `/` -> 200 with "no programs available" message

### Playwright Browser Tests

**File:** `t/playwright/tenant-storefront.spec.js`

1. **Landing page renders with program cards**
   - Seed tenant with programs/sessions
   - Navigate to root URL
   - Program cards visible with names, dates, prices

2. **Register button starts registration workflow**
   - Click "Register" on a session
   - Redirected to registration workflow first step

3. **Filters update listing**
   - Select a program type filter
   - Program listing updates to show filtered results

4. **Full session shows waitlist option**
   - Session at capacity shows "Join Waitlist" instead of "Register"

### Existing Test Updates

- `t/controller/camp-registration-*.t` -- Registration tests remain as-is
  (they test the registration workflow independently).
- Existing workflow tests (create-session.t, etc.) must still pass after
  engine fixes. The `index` method change should be backwards-compatible.

## Dependencies

- Existing workflow infrastructure (WorkflowProcessor, continuations)
- Existing `Schools#show` data loading logic (to be migrated)
- Existing `callcc` route (`/:workflow/:run/callcc/:target`)
- Existing tenant resolution (`$c->tenant` helper)

## Schema Migration

Workflows are stored per-schema. The `tenant-storefront` workflow must be
imported into every existing tenant schema, not just the registry schema.
The `clone_schema` function handles new tenants automatically, but existing
tenants need a one-time migration:

```perl
# One-time migration script
for my $tenant (@all_tenants) {
    my $dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $tenant->slug);
    $dao->import_workflows(['workflows/tenant-storefront.yaml']);
}
```

This can be a sqitch migration or a one-off script run during deployment.

## Design Decisions

1. **Return from registration**: When a registration workflow completes via
   continuation, the controller detects the parent is a completed
   single-step workflow and re-renders its latest step (the program listing).
   The parent sees the listing again and can register for another program.
   The registration workflow's own "complete" step shows confirmation
   before the return.

2. **Workflow run lifecycle**: The storefront uses session-based run reuse
   via `_find_or_create_run`. Authenticated users get stable runs across
   visits (keyed by session). Anonymous visitors get a run per browser
   session. Run IDs in `callcc` URLs remain valid as long as the session
   persists.

3. **Tiny Art Empire marketing page**: The `registry` tenant has a single
   program (the platform itself). Same `ProgramListing` step class, but a
   different template specified in the registry tenant's workflow YAML. The
   registry's workflow uses `template: tenant-storefront/marketing` while
   other tenants use `template: tenant-storefront/program-listing`. The step
   class returns data either way; the template decides how to render it.

4. **No intermediate migration state**: The old Landing and Schools
   controllers are removed in the same phase as the new storefront is added.
   No redirect shims or parallel routes. The switchover is atomic.
