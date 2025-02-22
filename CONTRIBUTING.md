# Contributing to Registry

Welcome to the Registry project! This document will help you understand the
core concepts and architecture of our platform, as well as guide you through
the development setup process.

## Mission

Registry empowers teachers to create and grow successful education businesses
by providing a unified platform for managing educational events. Our goal is to
handle the administrative complexity so teachers can focus on what they do
best: inspiring students.

## Development Environment Setup

### Using Docker (Recommended)

The easiest way to get started is using Docker and Docker Compose, which will
set up everything you need in isolated containers.

#### Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)

#### Setup Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/Tamarou/Registry.git
   cd Registry
   ```

2. Start the development environment:
   ```bash
   docker-compose up
   ```

3. The application will be available at http://localhost:3000

4. Database migrations will be automatically applied during the first startup.

### Manual Setup

If you prefer to set up the development environment directly on your system:

#### Prerequisites

- Perl 5.40.0 or higher
- PostgreSQL 12 or higher
- Git

#### Setup Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/Tamarou/Registry.git
   cd Registry
   ```

2. Install Perl dependencies:
   ```bash
   cpanm --installdeps .
   ```

3. Set up the PostgreSQL database:
   ```bash
   createdb registry
   sqitch deploy
   ```

4. Set the database URL environment variable:
   ```bash
   export DB_URL=postgres://username:password@localhost/registry
   ```

5. Start the development server:
   ```bash
   morbo registry
   ```

6. The application will be available at http://localhost:3000

## Running Tests

The Registry project uses a comprehensive test suite to ensure functionality works as expected.

### Running Tests with Docker

```bash
docker-compose run web prove -l t
```

### Running Tests Manually

```bash
prove -l t
```

### Testing Specific Components

To run tests for specific components:

```bash
prove -l t/controller/        # Test controllers
prove -l t/dao/               # Test data access objects
prove -l t/workflows/         # Test workflow functionality
```

## Database Migrations

Registry uses Sqitch for database migrations.

### With Docker

```bash
docker-compose run web sqitch deploy
```

### Manually

```bash
sqitch deploy
```

## Core Concepts

### Workflows

Workflows are the backbone of Registry, representing the entire lifecycle of an
educational event or program. Each workflow is a series of steps that guide
users through processes like program registration, attendance tracking, or
progress reporting.

Workflows are defined in YAML format for better readability and familiarity
with other workflow systems (like Kubernetes, Ansible, or GitHub Actions).
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
    roles:
      - parent
    conditions:
      registration_open: true
      class_capacity_available: true

  - name: Teacher Review
    outcome: application-review
    template: review-form
    roles:
      - teacher
      - admin
    requires:
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

### Templates

Templates define how workflow steps are presented to users. They are HTML templates that:
- Display forms for data collection
- Show progress and status information
- Present relevant information to users
- Handle user interactions

## Multi-tenant Architecture

Registry uses a schema-based multi-tenancy approach where each tenant
(organization) gets its own PostgreSQL schema with isolated data, while sharing
the same database instance. The application automatically routes requests to
the appropriate tenant schema based on the incoming request.

Key concepts:
- Each tenant has a unique identifier
- Workflows, templates, and outcomes are copied to each tenant's schema
- Cross-tenant queries are explicitly prevented for security
- Specialized workflow steps maintain their class information across tenant schemas

## Development Workflow

### Code Organization

The Perl codebase uses the following namespace structure:
- `Registry::DAO::OutcomeDefinition` - Handles outcome/schema definitions
- `Registry::DAO::Outcome` - Manages actual outcome data
- `Registry::DAO::Workflow` - Manages workflow execution (includes YAML parsing)
- `Registry::DAO::Template` - Handles template rendering

### Creating New Features

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/my-new-feature
   ```

2. Implement your changes, following these guidelines:
   - Write tests in the appropriate test directory
   - Keep the user personas in mind when developing features
   - Follow the coding style of the existing codebase
   - Document your code with appropriate comments
   - Update documentation as needed

3. Run the test suite to ensure everything works:
   ```bash
   prove -l t
   ```

4. Submit a pull request for review

### File Formats

- Workflows: YAML format for better readability and familiar workflow syntax
- Outcomes: JSON format for structured data validation
- Templates: HTML with template syntax for rendering

The choice of YAML for workflows aligns with developer expectations from other
workflow systems like Kubernetes, Ansible, and GitHub Actions, while providing
better readability and comment support for complex workflow definitions.

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

## Need Help?

- Check the existing documentation in `docs/`
- Review the user personas
- Ask questions in our development channels
- Submit issues for bugs or feature requests

We appreciate your contribution to making Registry better for educators!
