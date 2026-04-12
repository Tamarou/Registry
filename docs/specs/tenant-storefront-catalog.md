# Tenant Storefront Catalog Spec

## Audience

Nancy -- parent finding programs via online ad or school flyer. Has intent to register, not be sold on a concept.

## Page

`templates/tenant-storefront/program-listing.html.ep` (filesystem, initial version for all new tenants)

## Design

Vaporwave design system (theme.css + app.css). Mobile-first, responsive.

## Two Entry Points

1. **Generic** (ad, organic): `registration.superawesomecool.com` -- catalog of all programs
2. **Direct** (school flyer): links directly to a specific program's registration workflow (separate concern, friendly URLs TBD)

This spec covers entry point 1.

## Page Structure

### 1. Tenant Header

Tenant name from the landing-nav component.

### 2. Filter Bar

Dropdowns for:
- **Location** -- populated from locations linked to published sessions
- **Program type** -- populated from program_type_slug values in active programs
- **Date** -- filter by date range (from/to)

Progressive enhancement:
- **Base:** `<form method="GET">` with `<select>` elements. Submit reloads page with query params.
- **HTMX:** `hx-get` on filter controls with `hx-trigger="change"`, `hx-target` on program list. Partial page update without full reload.
- **Web component:** Future polish layer.

### 3. Program Cards Grouped by Program Type

Each group has a heading (e.g. "After-School Programs", "Summer Camps").

Each card shows:
- Program name
- Location name
- Dates (start - end of earliest/next session)
- Short description (from `project.notes`)
- Link: callcc to the program's registration workflow (friendly URLs TBD)

Cards use design system classes: `.landing-feature-card`, `.landing-feature-title`, `.landing-feature-description`.

### 4. Empty State

- "No programs match your filters" (when filters are active)
- "No programs currently available" (when no programs exist)

## Data

`ProgramListing.pm` needs to:
- Accept query params: `location`, `program_type`, `date_from`, `date_to`
- Filter the SQL query based on params
- Group results by `program_type_slug`
- Return grouped structure to the template

## Card Links

Currently: callcc URLs (`/tenant-storefront/<run_id>/callcc/<registration_workflow>?session_id=<id>&program_id=<id>`)

Future: tenant-configurable friendly URLs (design TBD -- `/:workflow/:program/:configured_key`)

## Scale

A tenant like SACP may have 40+ programs (30-40 school locations + summer camps). The page must handle this gracefully with grouping and filtering.
