# Admin Program Setup Specification

## Overview

Victoria (SACP program manager) needs to build out the upcoming school year's programs, sessions, and pricing through the Registry admin interface by **May 14, 2026** (kindergarten round-up at Dr Phillips). This spec covers the admin-facing workflows for creating, configuring, and publishing programs that parents can then register for.

## Architecture

### Orchestrator + Sub-Workflow Pattern

A parent workflow (`program-setup`) orchestrates the full setup flow using `callcc` continuations to chain independent sub-workflows. Each sub-workflow is also accessible independently for editing existing records.

```
program-setup (orchestrator)
  |-- callcc --> program-type-management (select existing or create new)
  |-- callcc --> program-creation (curriculum, requirements, schedule patterns)
  |-- callcc --> location-management (select existing or create new)
  |-- callcc --> program-location-assignment (assign program to locations, generate sessions/events)
  |-- callcc --> pricing-plan-creation (set pricing for sessions)
  |-- publish step (publish program, then individual sessions)
```

Each sub-workflow:
- Works standalone (accessible via direct URL and nav/dashboard links)
- Works as a callcc target from the orchestrator
- Supports both "create new" and "edit existing" modes via a "select or create" entry point

### Existing Workflows to Reuse

These workflows already exist and have step classes + templates:

| Workflow | Slug | Status |
|----------|------|--------|
| Program Creation | `program-creation` | Steps + templates exist, needs "select existing" entry point |
| Program Location Assignment | `program-location-assignment` | Steps + templates exist, needs testing |
| Pricing Plan Creation | `pricing-plan-creation` | Steps + templates exist, needs testing |
| Session Creation | `session-creation` | Old template naming convention, needs update |
| Event Creation | `event-creation` | Old template naming convention, needs update |

### New Workflows Needed

| Workflow | Slug | Purpose |
|----------|------|---------|
| Program Setup | `program-setup` | Orchestrator - chains sub-workflows via callcc |
| Program Type Management | `program-type-management` | Create/edit program types |
| Location Management | `location-management` | Create/edit locations |

## Data Model

### Program Type
- `name` (string, required) - e.g., "Summer Camp", "Art Class", "After-School Program"
- `slug` (string, auto-generated from name)
- `config` (jsonb) - type-specific configuration

Existing table: `program_types`. Verify schema supports CRUD.

### Location
- `name` (string, required) - e.g., "Dr Phillips Elementary"
- `address` (string, required)
- `capacity` (integer, required) - max students per session at this location
- `contact_person_id` (FK to `users`, required) - the person responsible for this location

Existing table: `locations`. Verify schema includes `contact_person_id`; add migration if missing. The contact person is a user account, so the Location Management workflow needs to support selecting an existing user or creating a new one (via callcc to account creation if needed).

### Program (Project)
- `name` (string, required)
- `program_type_slug` (FK to program_types, required)
- `notes` (text) - description
- `metadata` (jsonb) - curriculum, requirements, schedule patterns
- `published` (boolean, default false) **-- NEW FIELD**

Existing table: `projects`. Add `published` column via migration.

### Session
- `project_id` (FK to projects, required)
- `location_id` (FK to locations, required)
- `name` (string, required)
- `capacity` (integer, required)
- `status` (enum: upcoming/active/completed/cancelled)
- `published` (boolean, default false) **-- NEW FIELD**

Existing table: `sessions`. Add `published` column via migration.

### Publish Rules
1. A program must be published before any of its sessions can be published
2. Parents only see published sessions under published programs in the storefront
3. Unpublishing a program hides all its sessions from parents (regardless of session publish state)

## Workflow Specifications

### 1. Program Type Management (`program-type-management`)

**Steps:**
1. **list-or-create** - Show existing program types with edit links; "Create New" button
2. **type-details** - Name, description, configuration options
3. **complete** - Confirmation with link back to list or to orchestrator return

**Step Classes Needed:**
- `Registry::DAO::WorkflowSteps::ProgramTypeList`
- `Registry::DAO::WorkflowSteps::ProgramTypeDetails`

### 2. Location Management (`location-management`)

**Steps:**
1. **list-or-create** - Show existing locations with edit links; "Create New" button
2. **location-details** - Name, address, capacity
3. **select-contact** - Select existing user as contact person, or callcc to create a new account
4. **complete** - Confirmation with link back to list or to orchestrator return

**Step Classes Needed:**
- `Registry::DAO::WorkflowSteps::LocationList`
- `Registry::DAO::WorkflowSteps::LocationDetails`
- `Registry::DAO::WorkflowSteps::LocationContact`

### 3. Program Creation (`program-creation`) -- EXISTING, MODIFY

**Current Steps:**
1. `program-type-selection` - Select program type (add "create new type" callcc link)
2. `curriculum-details` - Name, description, curriculum
3. `requirements-and-patterns` - Age/grade requirements, schedule patterns
4. `review-and-create` - Review and create/update

**Changes Needed:**
- Add "select existing program to edit" as alternative entry path
- Add "create new type" callcc link in step 1
- Support edit mode (pre-populate fields from existing program)

### 4. Program Location Assignment (`program-location-assignment`) -- EXISTING, VERIFY

**Current Steps:**
1. `select-program` - Select which program to assign
2. `choose-locations` - Choose locations (add "create new location" callcc link)
3. `configure-location` - Per-location schedule, capacity overrides
4. `generate-events` - Generate sessions and events from schedule pattern
5. `complete` - Summary of created sessions/events

**Changes Needed:**
- Add "create new location" callcc link in step 2
- Verify end-to-end functionality

### 5. Pricing Plan Creation (`pricing-plan-creation`) -- EXISTING, VERIFY

**Current Steps:**
1. `plan-basics` - Name, description, target program/session
2. `pricing-model` - Pricing model configuration
3. `resource-allocation` - Resource allocation definitions
4. `requirements-rules` - Eligibility rules
5. `review-activate` - Review and activate

**Changes Needed:**
- Verify end-to-end functionality
- Ensure it can target specific sessions created in the previous step
- Pre-seed common pricing templates Victoria can select from

### 6. Program Setup Orchestrator (`program-setup`)

**Steps:**
1. **start** - "Set Up a Program" landing page. Two paths:
   - "Create New Program" - starts the full flow
   - "Continue Setting Up [existing program]" - shows in-progress programs
2. **select-or-create-type** - callcc to `program-type-management`, returns selected type
3. **create-program** - callcc to `program-creation`, returns created/selected program
4. **assign-locations** - callcc to `program-location-assignment`, returns created sessions
5. **set-pricing** - callcc to `pricing-plan-creation`, returns pricing plan
6. **publish** - Publish controls:
   - Toggle program published state
   - List sessions with individual publish toggles
   - "Preview as Parent" button for each
7. **complete** - Summary with links to manage individual pieces

**Step Class Needed:**
- `Registry::DAO::WorkflowSteps::ProgramSetupStart`
- `Registry::DAO::WorkflowSteps::ProgramPublish`

Most intermediate steps are thin wrappers that launch callcc and store return values.

### 7. Preview as Parent

- Available from the publish step and from individual program/session views
- Renders the storefront `program-listing` template filtered to show only the selected program
- Ignores publish state for preview (shows the program/session as if it were published)
- Clearly marked as "PREVIEW - Not visible to parents" with a visual indicator

## Navigation Changes

### Dashboard Nav Bar (admin/staff role)

Current: Dashboard | New Program | Attendance | Templates | Domains

Updated: Dashboard | Programs | Locations | Attendance | Templates | Domains

Where:
- **Programs** links to the program setup orchestrator (`/program-setup`)
- **Locations** links to location management (`/location-management`)

### Admin Dashboard

Add management links/buttons in the dashboard:
- "Program Overview" section: add "Set Up New Program" button, "Manage Programs" link
- New "Locations" card or section with "Manage Locations" link
- "Pricing" link from program cards to manage pricing for that program

## Database Migrations

### Migration: Add published columns

```sql
ALTER TABLE projects ADD COLUMN published BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE sessions ADD COLUMN published BOOLEAN NOT NULL DEFAULT false;
```

### Migration: Add location contact person (if missing)

Verify `locations` table schema. If `contact_person_id` is missing:

```sql
ALTER TABLE locations ADD COLUMN contact_person_id INTEGER REFERENCES users(id);
```

## Storefront Changes

The `ProgramListing` step must filter to only show published programs with published sessions. Update the query in `Registry::DAO::WorkflowSteps::ProgramListing` to add:

```sql
WHERE p.published = true AND s.published = true
```

## Seeded Data

Pre-seed the following for Victoria's initial use:

### Program Types
- After-School Program
- Summer Camp
- Art Class
- Workshop (single-day)

### Locations
- Dr Phillips Elementary (with address and contact info from Victoria)

### Pricing Templates
- Flat fee (single payment)
- Per-session pricing
- Sibling discount template (nice-to-have)

## Error Handling

- All form submissions validate required fields server-side before proceeding
- Database errors during creation display user-friendly messages with "try again" option
- callcc returns handle the case where the user cancels the sub-workflow (return to orchestrator without advancing)
- Publish step validates that required data exists before allowing publish:
  - Program has at least one session
  - Session has events generated
  - Session has pricing set
  - Display clear messages about what's missing

## Testing Plan

### Phase 1: Smoke Test Existing Workflows

Before writing new code, verify what currently works:

1. **Program Creation workflow** - Can an admin navigate through all 4 steps and create a project record?
2. **Program Location Assignment workflow** - Can it load programs, select locations, generate sessions?
3. **Pricing Plan Creation workflow** - Can it create a pricing plan and associate it with a session?
4. **Session Creation workflow** - Does it render with the old template naming?
5. **Admin Dashboard** - Does it load without errors for an admin user?

### Phase 2: Unit Tests for New Step Classes

For each new workflow step class:
- Test `process()` with valid form data
- Test `process()` with missing/invalid form data
- Test `prepare_template_data()` returns expected structure
- Test edit mode (pre-populated from existing record)

### Phase 3: Integration Tests

Test the orchestrator flow end-to-end:
1. Start program-setup workflow
2. Create a program type (via callcc)
3. Create a program (via callcc)
4. Create a location (via callcc)
5. Assign program to location and generate sessions (via callcc)
6. Set pricing (via callcc)
7. Publish program and sessions
8. Verify program appears in storefront catalog
9. Verify unpublished sessions do not appear

### Phase 4: Storefront Verification

1. Published program + published sessions appear in catalog
2. Published program + unpublished sessions do not show sessions
3. Unpublished program does not appear regardless of session state
4. Preview shows unpublished program/sessions correctly

### Phase 5: Edit/Management Tests

1. Navigate to existing program via program-type-management and edit
2. Navigate to existing location via location-management and edit
3. Edit program details via program-creation workflow in edit mode
4. Publish/unpublish toggles work correctly

## Priority Order for May 14

### Must Have
1. Smoke test existing workflows (find out what's broken)
2. Database migrations (published columns, location contact fields)
3. Program Type Management workflow (create/edit types)
4. Location Management workflow (create/edit locations)
5. Fix any broken existing workflows (program creation, location assignment, pricing)
6. Publish step (program + session level publish, storefront filtering)
7. Program Setup orchestrator (callcc chain)
8. Nav and dashboard links
9. Seed data (program types, Dr Phillips location)

### Nice to Have
1. Preview as Parent
2. Setup checklist on dashboard
3. Complex pricing templates (sibling discounts, installments)
4. Bulk session publish/unpublish
