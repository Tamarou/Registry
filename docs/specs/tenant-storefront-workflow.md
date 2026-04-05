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
- `templates/storefront/program-listing.html.ep` -- program listing template
- Route: root `/` dispatches to Workflows controller with
  `workflow => 'tenant-storefront'`

### Modify

- `lib/Registry.pm` -- replace root route, remove `/school/:slug` route

## Routing

The root route changes from a bespoke controller to the Workflows controller:

```perl
# Before
$self->routes->get('/')->to('landing#root')->name('root_handler');

# After
$self->routes->get('/')->to('workflows#index', workflow => 'tenant-storefront')->name('root_handler');
$self->routes->post('/')->to('workflows#start_workflow', workflow => 'tenant-storefront');
```

The `/:workflow` catch-all continues to handle all other workflows. The root
route is declared first (before the catch-all) and hardcodes the workflow
slug to `tenant-storefront`.

## Workflow Definition

```yaml
name: Tenant Storefront
slug: tenant-storefront
description: Public-facing landing page and program listing for a tenant
first_step: program-listing
steps:
  - slug: program-listing
    description: Browse Available Programs
    template: storefront/program-listing
    class: Registry::DAO::WorkflowSteps::ProgramListing
```

This is a single-step workflow. The step renders the program listing. The
"Register" buttons are `callcc` links that start continuation workflows
(e.g., `summer-camp-registration`). When a registration workflow completes,
the continuation returns to this workflow.

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
    # Return hashref with programs, sessions, filters, etc.
}

method process ($db, $form_data) {
    # The program-listing step doesn't advance -- it's a browsing step.
    # Registration happens via callcc links in the template.
    # If filters are submitted, store them in run data and stay.
    return { stay => 1 };
}
```

### Data Shape Returned by prepare_template_data

```perl
{
    programs => [
        {
            project   => $project_obj,
            program_type => $program_type_obj,  # may be undef
            sessions  => [
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

## Template: storefront/program-listing

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
           action="/<%= $workflow %>/<%= $run->id %>/callcc/summer-camp-registration">
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
   - Filters submit via HTMX to reload the program listing partial

4. **Layout**: Uses `layout 'default'` (not `layout 'workflow'`) since this
   is a public-facing page, not a multi-step form.

### callcc Target Resolution

The registration workflow slug for each program is determined by the
program's `program_type_slug`. The mapping:

- `summer-camp` → `summer-camp-registration`
- `afterschool` → `afterschool-registration` (future)
- Default → `summer-camp-registration` (for now)

This mapping lives in the template or in the step's `prepare_template_data`
return value. It is NOT a separate lookup -- it's just data.

## Migration Path

### Phase 1: Ship for Super Awesome Cool Pottery

1. Create `ProgramListing` step class with hardcoded query logic (migrated
   from Schools#show)
2. Create `storefront/program-listing.html.ep` template (adapted from
   schools/show and schools/_programs)
3. Create `tenant-storefront.yaml` workflow
4. Change root route to dispatch to `tenant-storefront` workflow
5. Import the workflow for all existing tenants
6. Keep `/school/:slug` route temporarily as a redirect to `/`

### Phase 2: Remove Legacy

1. Remove `Landing` controller
2. Remove `Schools` controller
3. Remove old templates (index.html.ep, schools/*)
4. Remove `/school/:slug` route

### Phase 3: Config-Driven (Future)

1. Add step metadata schema for query configuration
2. Build admin workflow for tenants to customize their storefront
3. Support SQL::Abstract query specs in step config

## Data Flow

```
Browser hits /
  → Route resolves to Workflows#index with workflow='tenant-storefront'
  → Workflows#index renders storefront/program-listing template
  → ProgramListing.prepare_template_data loads programs/sessions from tenant schema
  → Template renders program cards with callcc Register buttons

Parent clicks Register on "Week 1 - Jun 1-5"
  → POST /tenant-storefront/{run_id}/callcc/summer-camp-registration
  → Workflows#start_continuation creates a new run for summer-camp-registration
  → Registration workflow proceeds (account-check → select-children → ... → complete)
  → On completion, continuation returns to tenant-storefront
  → Parent sees confirmation or can register for another program
```

## Error Handling

- **No published sessions**: Template shows a message like "No programs
  currently available. Check back soon!" instead of an empty page.
- **Tenant not found**: Existing tenant resolution returns 'registry' as
  default, which shows the Tiny Art Empire marketing page.
- **Invalid filter values**: Ignored (treated as unfiltered). No 400 errors
  for bad query params.
- **callcc to nonexistent workflow**: The Workflows controller's
  `start_continuation` method will fail to find the workflow. This should
  render a user-friendly error, not a 500. Add error handling if not present.

## Testing Plan

### Perl Controller Tests

**File:** `t/controller/tenant-storefront.t`

1. **GET / returns 200 with program listing**
   - Create a tenant with programs and sessions
   - GET `/` → 200
   - Response contains program names and session names
   - Response contains "Register" buttons

2. **Programs from different tenants are isolated**
   - Create two tenants with different programs
   - GET `/` with tenant A context → shows only tenant A's programs
   - GET `/` with tenant B context → shows only tenant B's programs

3. **Only published sessions with future dates shown**
   - Create sessions with status=draft and status=published
   - Create sessions with past end_date and future end_date
   - GET `/` → only published future sessions appear

4. **Availability display correct**
   - Create session with capacity 16 and 14 enrollments
   - GET `/` → shows "2 spots left" or equivalent

5. **Full session shows waitlist option**
   - Create session at capacity
   - GET `/` → shows "Join Waitlist" instead of "Register"

6. **Filters narrow results**
   - Create sessions of different program types
   - GET `/?program_type=summer-camp` → only camp sessions shown

7. **callcc Register button creates continuation**
   - POST `/tenant-storefront/{run_id}/callcc/summer-camp-registration`
   - → 302 redirect to registration workflow
   - Workflow run has continuation_id set

8. **No programs shows empty state**
   - Tenant with no published sessions
   - GET `/` → 200 with "no programs available" message

### Playwright Browser Tests

**File:** `t/playwright/tenant-storefront.spec.js`

1. **Landing page renders with program cards**
   - Seed tenant with programs/sessions
   - Navigate to tenant subdomain root
   - Program cards visible with names, dates, prices

2. **Register button starts registration workflow**
   - Click "Register" on a session
   - Redirected to registration workflow first step

3. **Filters update listing via HTMX**
   - Select a program type filter
   - Program listing updates without full page reload

4. **Full session shows waitlist option**
   - Session at capacity shows "Join Waitlist" instead of "Register"

### Existing Test Updates

- `t/user-journeys/nancy/*.t` -- Nancy's journey should start from the
  storefront, not from a direct workflow URL. Update to begin at `/`.
- `t/controller/camp-registration-*.t` -- Registration tests can remain
  as-is (they test the registration workflow independently). Add a test
  that exercises the full callcc chain from storefront → registration →
  return.

## Dependencies

- Existing workflow infrastructure (WorkflowProcessor, continuations)
- Existing `Schools#show` data loading logic (to be migrated)
- Existing `callcc` route (`/:workflow/:run/callcc/:target`)
- Existing tenant resolution (`$c->tenant` helper)

## Design Decisions

1. **Return from registration**: When a registration workflow completes via
   continuation, the controller redirects back to the storefront. Since the
   storefront is a single-step workflow, the return lands back on the
   program-listing step. The parent sees the program listing again and can
   register for another program. The registration workflow's own "complete"
   step shows confirmation before the return.

2. **Workflow run lifecycle**: The storefront should reuse an existing
   incomplete run for the same user when possible (lookup by user session
   or cookie). This keeps `callcc` URLs valid across page visits. The
   Workflows controller's `index` method should check for an existing run
   before creating a new one. The `callcc` Register buttons embed the
   current run ID in the form action, so as long as the page is rendered
   with a valid run, the continuation works.

3. **Tiny Art Empire marketing page**: The `registry` tenant has a single
   program (the platform itself). Same `ProgramListing` step class, but a
   different template specified in the registry tenant's workflow YAML. The
   registry's `tenant-storefront.yaml` uses
   `template: storefront/marketing` while other tenants use
   `template: storefront/program-listing`. The step class returns data
   either way; the template decides how to render it.
