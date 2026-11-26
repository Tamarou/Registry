# Workflows

Workflows are the backbone of Registry, representing the entire lifecycle of an
educational event or program. Each workflow is a series of steps that guide
users through processes like program registration, attendance tracking, or
progress reporting.

## Core Concepts

### Workflow Definition

A workflow consists of:
- A unique name and slug
- A description of its purpose
- A series of ordered steps
- A designated first step
- Who may run it: a `roles` list, or the `public` mark

Workflows are usually defined by users via a Workflow construction workflow through the Registry Web UI. The system is bootstrapped using serialized workflows in YAML format for better readability and familiarity with other workflow systems (like Kubernetes, Ansible, or GitHub Actions).

Example workflow definition in YAML:

```yaml
name: Student Registration
description: |
  Handles the complete student registration process
  from initial application through confirmation.
slug: student-registration
# Who may run it. One of:
roles: [parent, admin, staff]
# public: true

steps:
  - name: Initial Application
    slug: initial-application
    description: Student application form
    template: application-form

  - name: Teacher Review
    slug: teacher-review
    description: Review of student application
    template: review-form

  - name: Confirmation
    slug: confirmation
    description: Final confirmation of enrollment
    template: confirmation-form
    class: Registry::DAO::WorkflowSteps::RegistrationComplete
```

## Workflow Components

### Roles and the Public Mark

Each workflow YAML declares one of:

- `roles`: a non-empty list of the application's roles (`parent`, `student`,
  `staff`, `admin` -- `Registry::DAO::User::USER_TYPES`). An unknown name, an
  empty list, or anything but a list is refused at import.
- `public: true`: anyone may walk into it. Only a YAML boolean `true` is the
  mark; `1`, `yes`, `"true"` and every false value are not.

Import enforces at most one: declaring both is refused, with the file named
in the error. `t/security/workflow-roles-cover-every-workflow.t` enforces at
least one for every shipped workflow; import still accepts a YAML with
neither.
`from_yaml` stores the entry on the `workflows` row (`roles`, `public`),
`to_yaml` round-trips it, and `copy_workflow` carries it into a tenant's
schema. A row with neither has no entry, and the gate refuses it (see "Who
may run a workflow" below).

### Who may run a workflow

The gate (`require_workflow_role` in `lib/Registry.pm`) guards every entry to
a workflow: the `/:workflow` routes, the routes that name their workflow in
the route rather than the URL (`/`, `/admin/dashboard`, the drop and transfer
approvals, `/admin/templates`), and the callcc leg, which names its target
workflow in another placeholder.

It first asks whether the request's tenant may run the slug at all
(`Registry::DAO::Entitlement->tenant_may_run`, below), whoever is asking. A
tenant without the run right is refused 403 before any role is read: an
admin, an anonymous visitor to a public workflow such as the storefront, a
step POST on a run parked before the right ended, and a callcc into the slug
all alike, and no run is created. The tenant is the one the request resolves
to (`$c->tenant`), so a form `__tenant_slug`, an `X-As-Tenant` header or an
`as-tenant` cookie naming another tenant borrows nothing. A lookup that
errors refuses and is logged: the gate fails closed. The platform tenant
`registry` passes the same way, by holding its own run rights, never by a
slug check. `t/security/workflow-run-requires-entitlement.t` proves each case.

Then it reads the current tenant's own `workflows` row for the slug:

- the public mark admits anyone, signed in or not;
- roles admit a user whose role in this tenant is one of them (an anonymous
  visitor is sent to log in, a signed-in user with another role gets 403);
- anything else is refused 403, for everyone, admins included: a row with no
  roles (or an empty list) and no public mark, or no row at all in this
  tenant's schema. The gate never falls back to `registry`'s row, so
  `tenant-signup`, which no tenant is granted or copied, is refused on a
  tenant host, and one tenant's public copy never opens another's.

A slug with no row and no legacy `{slug}/index` template is a 404 before the
gate runs. A refused request creates no run.

The gate checks the slug, not the run. A step URL (`/:workflow/:run/:step`,
including Stripe's return to it) and a callcc's source run are served only
when the run belongs to the URL's workflow in this tenant's schema; any other
run id is a 404, so a run of an admin-only workflow cannot be continued
through a public slug, nor its existence confirmed. Runs the
`ContinueWorkflowRun` job or the Stripe Connect webhook create never pass
through these routes. A workflow a step starts internally through
`Registry::Utility::WorkflowProcessor` (the transfer and drop processing that
`ProcessAdminTransferDecision` and `ProcessAdminDropDecision` start) is not
gated itself: it is gated by the entry to the outer workflow whose step
starts it. The hard-coded `%ROLES` map that
`lib/Registry.pm` once held is gone; the rows are the only source.

A tenant-chosen registration workflow (a project's `registration_workflow`
metadata) stays reachable because its YAML carries the public mark, as
`summer-camp-registration`'s does. A workflow a tenant writes through
`workflow-creation` gets that authoring workflow's own roles. That is an
inference, not a ruling: ADR 004(b) settles the tenant's entitlement to
create workflows, not which users may run them. It fails closed, admitting
no one the authoring workflow would not.

#### Run rights: what a tenant is entitled to run

Separately from roles, a tenant's right to run a workflow is an entitlement
it holds from the platform tenant `registry` (PriceOps spec, "The platform
tenant's offers"). Each workflow slug the platform offers is a resource named
`run:<slug>`. The right to create workflows is `run:workflow-creation`, and it
also covers running the workflows the tenant wrote (ADR 004, ruling (b)).
The gate above requires them.

- **Tenant-authored workflows.** perigrin's ruling (b) in ADR 004: "(a)
  Create right covers run (Recommended)". A slug `registry` has no workflow
  for is one the platform offers no run right to, so the tenant wrote it
  (through `workflow-creation`, or a tenant-only slug kept by a divergence
  ruling). `tenant_may_run` admits it when the tenant holds
  `run:workflow-creation`. A copy of a slug `registry` does have always needs
  that slug's own run right.

- **The check.** `Registry::DAO::Entitlement->may_run($db, $tenant_id, $slug)`
  answers from live rows through `Registry::DAO::Tenant->holds`. It is true
  only when the tenant holds `run:$slug` in `registry`, in effect now (active,
  its period covering now), under a single-resource version or a set version.
  The name must match exactly, so a pattern, another case or a trailing space
  answers false. A right a tenant records in its own schema grants nothing,
  and neither does another tenant's right.
- **One at a time.** A holder holds at most one in-effect run right per
  workflow, whatever the payment plan. The `entitlement_one_run_right` trigger
  enforces this in `registry`, looking through set versions. An ended right
  never blocks its successor.
- **The backfill** (`workflow-run-entitlements`). `registry` holds one run
  right per workflow in `registry.workflows` at deploy, through its own
  per-slug offer to itself (`holder_is_offerer`), as the bootstrap seeded the
  five product-design rights. Those five are reused, never duplicated.
- **At import** (`registry-run-right-at-import`). A trigger on
  `registry.workflows` grants `registry` the run right to each workflow
  inserted there, the same way, so a fresh database (which imports after
  deploy) and every later import leave `registry` able to run its own
  workflows. Its deploy also grants any workflow imported since the backfill.
- **How a new workflow reaches a Solo holder.** perigrin's ruling (a) in
  ADR 004: "(a) New Solo version". A new Solo version lists the workflow set
  as a set version, published through offer-publishing, and holders move to
  it. The rule for moving them waits until real holders exist. Day one still
  sells a single-resource Solo.
- **Studios hold their run rights through Solo.** Solo v2's set
  (`solo-grants-workflow-set`) lists a run right for every shipped workflow
  but `tenant-signup` and `registry-storefront`, which only `registry` runs:
  the signup funnel and the apex storefront are `registry`'s. A studio gains
  them by accepting Solo at signup. The backfill refuses to deploy while any
  studio tenant holds workflow copies, naming each. Production has none.
  A dev database with a seeded SACP tenant must re-create it (see
  `sql/seed/README.md`).

**Changing who may run an existing workflow ships a migration.** `from_yaml`
returns an existing row unchanged and a tenant's copies are written only by
`copy_workflow` when the tenant accepts an offer, so editing a YAML's `roles` or `public` alone
changes only fresh databases. The change needs a sqitch migration that
updates `registry` and every tenant schema, looping over `registry.tenants`
as `workflow-roles-data` does. Clearing the stored workflow so import rebuilds
it, as `entitlement-stripe-move-adds-dispute-step` does, reaches `registry`
only; the tenants' copies still need the update.
`t/dao/workflow-roles-data.t` fails for a shipped YAML whose entry disagrees
with the row migrations carried forward, and
`t/security/workflow-gate-closed-by-default.t` proves the gate's refusals.

### Workflow Steps

A workflow step is a single unit of work that users interact with. Each step is defined by:
- A unique slug (within the workflow)
- A description
- A template ID (optional)
- Metadata (JSON)
- A dependency on a previous step (used for ordering)
- A class name (for specialized steps)

The database stores steps with references to their workflow and dependencies:

```sql
CREATE TABLE IF NOT EXISTS workflow_steps (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    slug text NOT NULL,
    description text NULL,
    workflow_id uuid NOT NULL REFERENCES workflows,
    template_id uuid REFERENCES templates,
    metadata jsonb NULL,
    depends_on uuid REFERENCES workflow_steps,
    class text NULL,
    created_at timestamp with time zone DEFAULT now(),
    UNIQUE (workflow_id, slug)
);
```

#### Specialized Workflow Steps

A key feature of Registry's workflow system is the ability to create specialized workflow step classes. These classes inherit from `Registry::DAO::WorkflowStep` and override the `process` method to implement custom logic.

Examples of specialized workflow steps include:
- `Registry::DAO::WorkflowSteps::CreateProject` - Creates a project and adds it to the workflow data
- `Registry::DAO::WorkflowSteps::CreateUser` - Creates a user account
- `Registry::DAO::WorkflowSteps::CreateEvent` - Creates an event
- `Registry::DAO::WorkflowSteps::RegisterTenant` - Sets up a new tenant in the system

Specialized workflow steps allow for complex business logic to be encapsulated within a workflow step, making workflows more powerful while keeping their definition simple.

**Which classes a step may name.** A step's `class` is accepted only if it is `Registry::DAO::WorkflowStep` itself or a module shipped under `lib/Registry/DAO/WorkflowSteps/` (`Registry::WorkflowStepClasses::is_allowed`). The list is derived from that directory, located from the allowlist module's own file rather than `@INC`, so adding a step class means adding its file there. Every write of the column goes through the check: `WorkflowStep->create` (and so `Workflow->add_step`, `from_yaml` and the workflow-creation workflow, which checks every submitted step before storing any) and `WorkflowStep->update`. A tenant composes allowed steps; it never names code. The decision and its alternatives are recorded in [ADR 002](../decisions/002-workflow-step-class-allowlist.md).

Loading is checked too, because a stored row is not trusted: it may predate the creation check, have been written around the DAO, or sit in a tenant schema's own `workflow_steps`. `WorkflowStep->find` refuses a stored class outside the allowlist before loading anything, loads an allowed one with `Module::Runtime::require_module` (never a string `eval`, which would run the column as Perl), and refuses a loaded class that is not a `Registry::DAO::WorkflowStep` before its constructor runs. The caller sees `find` die with "'<class>' is not an allowed workflow step class" (or "<class> is not a workflow step"); a workflow whose first step is refused cannot be started, and `Registry::WorkflowProcessor->new_run` leaves no run behind for it.

### Outcomes

Outcomes define what successful completion of a workflow step looks like. They specify the data that needs to be collected and validated at each step of a process.

Outcomes are defined in JSON format:

```json
{
  "name": "Student Registration",
  "description": "Collect essential student information",
  "fields": [
    {
      "id": "studentName",
      "type": "text",
      "label": "Student Name",
      "required": true
    },
    {
      "id": "gradeLevel",
      "type": "select",
      "label": "Grade Level",
      "required": true,
      "options": [
        "k: Kindergarten",
        "1: First Grade",
        "2: Second Grade"
      ]
    }
  ]
}
```

### Templates

Templates define how workflow steps are presented to users. They are HTML templates that:

- Display forms for data collection
- Show progress and status information
- Present relevant information to users
- Handle user interactions

The database stores templates with the following structure:

```sql
CREATE TABLE IF NOT EXISTS templates (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    content text NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now()
);
```

### Validations

Validations define how system state is validated at each step of a workflow. See the [validation system documentation](validation-system.md) for details on:

- Field-level validations
- Business logic validations
- Validation templates

## Workflow Execution

### Workflow Runs

When a user interacts with a workflow, a workflow run is created. The run tracks:
- The workflow being executed
- The current step
- The user performing the workflow
- Data collected throughout the workflow
- A reference to a continuation workflow (if applicable)

```sql
CREATE TABLE IF NOT EXISTS workflow_runs (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    workflow_id uuid NOT NULL REFERENCES workflows,
    latest_step_id uuid REFERENCES workflow_steps,
    continuation_id uuid NULL REFERENCES workflow_runs,
    user_id uuid NULL REFERENCES users,
    data jsonb NULL,
    created_at timestamp with time zone DEFAULT now()
);
```

Workflow runs maintain a JSON document of collected data, which is updated as users progress through the workflow steps.

### Step Navigation

Workflow steps are connected in a linear sequence using the `depends_on` field. The workflow system provides methods to:

- Get the first step of a workflow
- Get the next step after a given step
- Get the last step of a workflow

### Runs no person is waiting on

Some steps happen after the person has left: a refund settling, the second half
of a change, a move Stripe reports, an expiry. The Minion task
`continue_workflow_run` (`lib/Registry/Job/ContinueWorkflowRun.pm`) drives those.
It takes `{ tenant => <schema slug>, run_id => <uuid> }`, connects to that
tenant's schema, and processes the run's next step, then the next, from
`latest_step_id`, until the run completes or a step needs a person. A step's
result and the advance of `latest_step_id` are written in one statement, so a
step whose result was persisted is never run again.

Only one driver works on a run at a time. The job takes a Postgres advisory lock
keyed by the run id; a second job for the same run waits for it, then finds the
run where the first left it.

When a step dies, the job records on the run, under the server-owned key
`__driver`, `{ step, attempt, error, at }`, and fails, and Minion retries it
(enqueue it with `attempts => 3`). The last failed attempt also records
`state => 'halted'`. A drive that ends without dying clears `__driver`. Clients
cannot write `__driver`: the workflow controller strips it from every form.

**A half-finished run** is one parked at `latest_step_id` with
`__driver.state = 'halted'`. Every step up to and including `latest_step_id` has
fully happened; the step named in `__driver.step` (the next one) and every step
after it has not been persisted. If that step moves money, its call may have
reached Stripe before the job died: Stripe is the truth. The webhook Stripe sends
for it, or re-running the step, settles it, because a money-moving step sends
Stripe an idempotency key derived from state it saved before the call (the
payment row it links to the run, as `pi-create:<token>`; `refund:capacity:...`
for a capacity refund), and Stripe answers a repeated key with its first answer
rather than moving the money again.

To resume a halted run, an admin fixes what `__driver.error` names, then
enqueues `continue_workflow_run` again with the same arguments. The driver
starts at the halted step, not the first one.

The `attendance_check` sweep (`lib/Registry/Job/AttendanceCheck.pm`) uses the
same driver in-process: each check starts an `attendance-check` run in the
registry schema and drives it to the end. The driver returns where the run
stopped and leaves finishing the Minion job to its caller, so the sweep finishes
with the tenants it covered. The sweep's next run is queued by
`Registry::Job::Recurring`, never from run data. A check gets one attempt, so a
step that dies halts that run and alerts registry's admins at once.

## Advanced Features

### Continuations

Continuations are a powerful feature that allows one workflow to start another workflow while passing contextual data between them. This enables:

1. Breaking complex processes into smaller, reusable workflows
2. Creating workflow libraries that can be composed together
3. Allowing different user roles to participate in a connected process

When a workflow run has a continuation, it sets the `continuation_id` field to reference another workflow run. Specialized workflow steps can check for continuations and update them with data processed in the current workflow.

Example of continuation logic in a specialized step:

```perl
method process ( $db, $ ) {
    my ($workflow) = $self->workflow($db);
    my $run        = $workflow->latest_run($db);
    my %data       = $run->data->%{ 'name', 'metadata', 'notes' };
    my $project    = Registry::DAO::Project->create( $db, \%data );

    # Update the current run with the project ID
    $run->update_data( $db, { projects => [ $project->id ] } );

    # If this workflow is a continuation of another, update that one too
    if ( $run->has_continuation ) {
        my ($continuation) = $run->continuation($db);
        my $projects = $continuation->data->{projects} // [];
        push $projects->@*, $project->id;
        $continuation->update_data( $db, { projects => $projects } );
    }

    return { project => $project->id };
}
```

### Workflow Composition

In Registry, workflows can be composed by using specialized workflow steps that initiate new workflows. This pattern allows for:

1. Modularity - Building complex processes from simpler components
2. Reusability - Common workflows can be reused across different processes
3. Role separation - Different workflows can be assigned to different user roles

Who may reach a workflow directly is its stored roles or public mark; see "Who may run a workflow" above.

Example of a specialized workflow step that initiates another workflow:

```perl
class Registry::DAO::InitiateProjectWorkflow :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $ ) {
        my ($workflow) = $self->workflow($db);
        my $run        = $workflow->latest_run($db);

        # Find the project creation workflow
        my $project_workflow = Registry::DAO::Workflow->find(
            $db, { slug => 'project-creation' }
        );

        # Create a new run of that workflow
        my $project_run = $project_workflow->new_run(
            $db, { continuation_id => $run->id }
        );

        # Return reference to the new workflow run
        return { project_workflow_run => $project_run->id };
    }
}
```

### Multi-tenant Support

A tenant runs its own copy of a platform workflow, in its own schema. The copy arrives when the tenant accepts the platform's offer that grants the workflow's run right (`run:<slug>`): `Registry::DAO::Tenant->accept_platform_offer`, which tenant signup's accept step (`TenantPayment`, through `provision`) calls. Never a CLI or a migration. Accepting copies each workflow the offer version grants, from `registry` only, into the accepting tenant's schema only; submitted data naming another tenant or schema is ignored. The copy brings the workflow's steps with their classes, its templates, the outcome definitions its steps use, and its role data (`roles` or the `public` mark). The accept and the copies are one transaction: a copy that fails leaves no entitlement and no partial workflow.

A tenant that already holds a copy of the slug:

- keeps it when it is the same as the platform's, by the divergence comparison below, so there is still one copy;
- has it replaced by the platform's definition only under a `Ruling: replace <tenant>/<slug>` line in `docs/reviews/tenant-workflow-divergence.md`, perigrin's recorded rulings;
- otherwise keeps it: under a `Ruling: merge <tenant>/<slug>` line, which needs a hand merge, or with no ruling. The accept's result names each kept copy, why, and its differences.

So a new tenant's workflows are exactly those its accepted offer's entitlements grant. Provisioning copies no others: it no longer copies every `registry` workflow, nor skips `tenant-signup` and `registry-storefront` by slug. No offer grants those two to a studio, and the accept never copies a workflow `Registry::WorkflowDivergence::never_copied` names even if one did. A tenant provisioned without accepting an offer holds no workflows. Migrations that reset a workflow change only `registry`'s copy, so a tenant's copy can fall behind or be edited away from the platform's. To see how, run:

```bash
carton exec ./registry workflow divergence registry
```

It compares every tenant schema in `registry.tenants` with `registry`, and is read-only: it only runs `SELECT`s. For each tenant it reports:

- a slug the tenant has that `registry` does not, and a `registry` slug the tenant lacks. `tenant-signup` and `registry-storefront` are never copied to a tenant, so their absence is expected and not reported; a tenant that does hold one is reported;
- for a shared slug, the step order (the `first_step`/`depends_on` walk), and for each shared step its `class`, its template by name, and its template by exact content (no whitespace normalising; content is shown as a sha256 prefix and byte length). One template difference is expected and not reported: provisioning unlinks the tenant's `tenant-storefront` `program-listing` template on purpose (#173, #229), because registry's is the platform's marketing page and a tenant must fall back to its catalog on disk. Only the tenant having no template there is excused; a tenant step linked to some other template is still reported.

Every difference names the field and both values. `registry` itself is never a section, and a tenant whose schema is missing or unreadable gets an error line while the others are still compared. The output is Markdown, one section per tenant in slug order, and is what `docs/reviews/tenant-workflow-divergence.md` records.

## YAML Examples

### Basic Workflow

```yaml
name: Event Creation
description: Create a new event in the system
slug: event-creation

steps:
  - slug: event-details
    description: Enter basic event information
    template: event-details-form

  - slug: location-selection
    description: Select a location for the event
    template: location-selection-form

  - slug: teacher-assignment
    description: Assign a teacher to the event
    template: teacher-selection-form

  - slug: create-event
    description: Create the event in the system
    class: Registry::DAO::WorkflowSteps::CreateEvent
```

### Workflow With Continuations

```yaml
name: Session Creation
description: Create a new session with multiple events
slug: session-creation

steps:
  - slug: session-details
    description: Enter basic session information
    template: session-details-form

  - slug: create-events
    description: Start event creation workflow
    class: Registry::DAO::WorkflowSteps::InitiateEventWorkflow  # illustrative: would need a shipped file

  - slug: review-events
    description: Review created events
    template: event-review-form

  - slug: create-session
    description: Create the session with events
    class: Registry::DAO::WorkflowSteps::CreateSession
```

### Specialized Workflow Step

```yaml
name: User Creation
description: Create a new user account
slug: user-creation

steps:
  - slug: user-details
    description: Enter user information
    template: user-details-form

  - slug: create-user
    description: Create the user account
    class: Registry::DAO::WorkflowSteps::CreateUser

  - slug: confirmation
    description: Confirm user creation
    template: user-confirmation-form
```

## Implementation

The Perl codebase implements workflows using the following classes:

- `Registry::DAO::Workflow` - Manages workflow definitions and execution
- `Registry::DAO::WorkflowStep` - Base class for all workflow steps
- `Registry::DAO::WorkflowRun` - Tracks workflow execution and data
- Specialized step classes (e.g., `Registry::DAO::WorkflowSteps::CreateUser`) - Implement custom logic

## Development Guidelines

When developing new workflows:

1. Consider breaking complex workflows into smaller, reusable components
2. Use continuations to connect related workflows
3. Create specialized workflow step classes for complex business logic
4. Ensure workflow steps have clear, descriptive names and slugs
5. Document the purpose and requirements of each workflow
6. Test workflows thoroughly, especially those with continuation
