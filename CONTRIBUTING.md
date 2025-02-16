# Contributing to Registry

Welcome to the Registry project! This document will help you understand the
core concepts and architecture of our platform.

## Mission

Registry empowers teachers to create and grow successful education businesses
by providing a unified platform for managing educational events. Our goal is to
handle the administrative complexity so teachers can focus on what they do
best: inspiring students.

## Core Concepts

### Workflows

Workflows are the backbone of Registry, representing the entire lifecycle of an
educational event or program. Each workflow is a series of steps that guide
users through processes like program registration, attendance tracking, or
progress reporting. Workflows are usually defined by users via a Workflow
construction workflow. This is driven via the Registration Web UI.

We bootstrap the system using serialized workflows in YAML format for better
readability and familiarity with other workflow systems (like Kubernetes,
Ansible, or GitHub Actions).

Example:

```yaml
name: Student Registration
description: |
  Handles the complete student registration process
  from initial application through confirmation.

steps:
  - name: Initial Application
    outcome: student-application  # references outcome definition
    template: application-form   # references template
    roles: # NOT IMPLEMENTED YET
      - parent
    conditions: # NOT IMPLEMENTED YET
      registration_open: true
      class_capacity_available: true

  - name: Teacher Review
    outcome: application-review
    template: review-form
    roles: # NOT IMPLEMENTED YET
      - teacher
      - admin
    requires: # NOT IMPLEMENTED YET
      - Initial Application
```

### Outcomes

Outcomes define what successful completion of a workflow step looks like. They
specify the data that needs to be collected and validated at each step of a
process.

For example, a "Student Registration" outcome might specify that we need:
- Student name (required)
- Grade level (must be K-8)
- Parent contact information
- Emergency contact details
- Medical notifications

Outcomes are defined in JSON format. Example:

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
### Validations (NOT IMPLEMENTED YET)

Validations define how system state is validated at each step of a workflow.
See the [design doc](docs/architecture/validations.md) for more details.

### Templates

Templates define how workflow steps are presented to users. They are HTML
templates that:

- Display forms for data collection
- Show progress and status information
- Present relevant information to users
- Handle user interactions

## Roles (NOT IMPLEMENTED YET)

Roles define which users are allowed to interact with a workflow step.

## Conditions (NOT IMPLEMENTED YET)

Conditions define what preconditions must be met to allow a user to interact
with a workflow step.

## Example Content and Bootstrapping

While Registry stores all user-created content (outcomes, templates, and
workflows) in the database, the repository contains example and default content
used to bootstrap the system. These files serve as both initial defaults and as
reference implementations for developers.

```
Registry/
├── schemas/      # Example and default outcome definitions (JSON)
├── templates/    # Default HTML templates for workflow steps
└── workflows/    # Example workflow definitions (YAML)
```

These files are used to:
- Initialize a new Registry installation with sensible defaults
- Provide working examples for developers
- Define the core workflows that ship with the system
- Document the expected structure and format of each content type

When developing new features or modifying existing ones, these example files serve as valuable references, but remember that in a running system, this content will be stored and managed in the database.

## Code Organization

The Perl codebase uses the following namespace structure:
- `Registry::DAO::OutcomeDefinition` - Handles outcome/schema definitions
- `Registry::DAO::Outcome` - Manages actual outcome data
- `Registry::DAO::Workflow` - Manages workflow execution (includes YAML parsing)
- `Registry::DAO::Template` - Handles template rendering

## File Formats

- Workflows: YAML format for better readability and familiar workflow syntax
- Outcomes: JSON format for structured data validation
- Templates: HTML with template syntax for rendering

The choice of YAML for workflows aligns with developer expectations from other workflow systems like Kubernetes, Ansible, and GitHub Actions, while providing better readability and comment support for complex workflow definitions.

## Getting Started

1. Familiarize yourself with the user personas in `docs/personas/`
2. Review existing workflows in the `workflows/` directory (YAML format)
3. Look at outcome definitions in `schemas/`
4. Examine templates in `templates/`

## Development Guidelines

1. Keep the user personas in mind when developing features
2. Ensure new workflows are clear and intuitive
3. Write clear outcome definitions with helpful validation messages
4. Make templates responsive and accessible
5. Document any new features or changes
6. Use YAML comments to explain complex workflow logic
7. Remember these files are examples - production content lives in the database

## Need Help?

- Check the existing documentation in `docs/`
- Review the user personas
- Ask questions in our development channels
- Submit issues for bugs or feature requests

We appreciate your contribution to making Registry better for educators!
