# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Development
```bash
# Start development server with auto-reload
make dev-server  # or: carton exec morbo ./registry

# Run the full test suite
make test  # or: carton exec prove -lr t/

# Run a specific test file
carton exec prove -lv t/dao/workflows.t

# Reset database (drop, create, deploy schema, import data)
make reset

# Deploy database migrations only
carton exec sqitch deploy

# Import workflows and templates
carton exec ./registry workflow import registry
carton exec ./registry template import registry
```

### Docker Development
```bash
docker-compose up  # Start all services
```

## Architecture Overview

Registry is a Perl-based web application for managing after-school programs and educational events, built with:
- **Mojolicious** web framework
- **PostgreSQL** database with **Mojo::Pg** ORM
- **HTMX** for dynamic frontend interactions
- **Object::Pad** for modern OOP with feature classes

### Core Concepts

1. **Workflows**: The backbone of Registry. All processes (registrations, event creation, etc.) are implemented as workflows with steps:
   - Defined in YAML files under `workflows/`
   - Each step can have custom logic via specialized classes in `lib/Registry/DAO/WorkflowSteps/`
   - Workflows support continuations for multi-session processes
   - Steps include: forms, redirects, decisions, conditions, and custom actions

2. **Multi-Tenant Architecture**: Schema-based isolation for different organizations

3. **Outcome Definitions**: JSON Schema-based form definitions that integrate with workflows

4. **MVC Structure**:
   - Controllers: `lib/Registry/Controller/` - Handle HTTP requests
   - DAOs: `lib/Registry/DAO/` - Data access and business logic
   - Templates: `templates/` - HTML templates with HTMX integration

### Key Patterns

- **Feature Classes**: All DAOs and Controllers use Object::Pad with the following structure
```perl
use 5.34.0;
use experimental 'signatures';
use Object::Pad;
class Foo :isa(Bar) {
    field $name :param :reader = 'default';

    method update_name($new) { $name = $new }
}
````
- **Database Migrations**: Managed via Sqitch (see `sql/` directory)
- **Test Structure**:
  - Unit tests for DAOs in `t/dao/`
  - Controller tests in `t/controller/`
  - User journey tests in `t/user-journeys/`
- **Template Extension**: Templates can specify a different workflow layout via `extends 'layouts/workflow'`

### Important Notes

- When modifying workflows, remember to re-import them with the workflow import command
- The workflow processor (`lib/Registry/Utility/WorkflowProcessor.pm`) handles workflow execution
- Custom workflow steps must inherit from base step classes and implement required methods
- HTMX attributes are used extensively for dynamic behavior without full page reloads

## Production Features

Registry is production-ready with comprehensive implementations for:

### Core Functionality
- **Multi-child registration**: Complete family enrollment workflows
- **Waitlist management**: Automated progression with email notifications  
- **Payment processing**: Stripe integration with Minion background jobs
- **Admin dashboards**: Program management, enrollment tracking, financial reporting
- **Parent dashboards**: Child status, attendance, messaging, payment history
- **Staff management**: Role-based access for instructors and administrators

### Security & Performance
- **Input validation**: Comprehensive security tests for SQL injection and XSS prevention
- **Database optimization**: Production-ready indexes and query optimization
- **Error handling**: User-friendly error messages with proper loading states
- **Background processing**: Automated email notifications and waitlist management
- **Mobile responsive**: Full mobile experience with HTMX interactions

### Testing Coverage
- **End-to-end tests**: Complete user journey validation (`t/e2e/`)
- **Security audits**: Input validation and attack prevention (`t/security/`)
- **User story tests**: Persona-based validation (`t/user-journeys/`)
- **Integration tests**: Workflow and payment processing validation

See README.md for complete production deployment checklist and configuration details.
