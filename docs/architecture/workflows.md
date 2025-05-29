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

Workflows are usually defined by users via a Workflow construction workflow through the Registry Web UI. The system is bootstrapped using serialized workflows in YAML format for better readability and familiarity with other workflow systems (like Kubernetes, Ansible, or GitHub Actions).

Example workflow definition in YAML:

```yaml
name: Student Registration
description: |
  Handles the complete student registration process
  from initial application through confirmation.
slug: student-registration

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
    class: Registry::DAO::EnrollStudent
```

## Workflow Components

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
- `Registry::DAO::CreateProject` - Creates a project and adds it to the workflow data
- `Registry::DAO::CreateUser` - Creates a user account
- `Registry::DAO::CreateEvent` - Creates an event
- `Registry::DAO::RegisterTenant` - Sets up a new tenant in the system

Specialized workflow steps allow for complex business logic to be encapsulated within a workflow step, making workflows more powerful while keeping their definition simple.

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

Registry supports multi-tenant deployments, where workflows can be copied between tenants. The system ensures that all workflow components (steps, templates, etc.) are properly copied to maintain functionality across tenants.

When copying workflows between tenants, it's essential to preserve the class information for specialized workflow steps. The `copy_workflow` function handles this by including the `class` column when duplicating workflow steps.

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
    class: Registry::DAO::CreateEvent
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
    class: Registry::DAO::InitiateEventWorkflow

  - slug: review-events
    description: Review created events
    template: event-review-form

  - slug: create-session
    description: Create the session with events
    class: Registry::DAO::CreateSession
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
    class: Registry::DAO::CreateUser

  - slug: confirmation
    description: Confirm user creation
    template: user-confirmation-form
```

## Implementation

The Perl codebase implements workflows using the following classes:

- `Registry::DAO::Workflow` - Manages workflow definitions and execution
- `Registry::DAO::WorkflowStep` - Base class for all workflow steps
- `Registry::DAO::WorkflowRun` - Tracks workflow execution and data
- Specialized step classes (e.g., `Registry::DAO::CreateUser`) - Implement custom logic

## Development Guidelines

When developing new workflows:

1. Consider breaking complex workflows into smaller, reusable components
2. Use continuations to connect related workflows
3. Create specialized workflow step classes for complex business logic
4. Ensure workflow steps have clear, descriptive names and slugs
5. Document the purpose and requirements of each workflow
6. Test workflows thoroughly, especially those with continuation
