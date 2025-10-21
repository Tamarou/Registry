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

## Test Requirements

**CRITICAL: 100% Test Pass Rate Required**

Registry maintains a 100% test pass rate across all test suites. This is a strict requirement:

- **ALL tests must pass before any PR can be merged**
- **NO failing tests are acceptable** - even cosmetic or "minor" failures block merges
- **NO TODO/skip tests without explicit approval** from perigrin
- If tests fail due to your changes, you MUST fix them before the work is considered complete
- The CI system enforces this requirement automatically

Current test coverage includes:
- Unit tests: `t/dao/` (18/18 passing)
- Controller tests: `t/controller/` (26/26 passing) 
- Integration tests: `t/integration/` (20/20 passing)
- Security tests: `t/security/` (comprehensive input validation)
- End-to-end tests: `t/e2e/` (complete user journeys)

**Test execution must be pristine** - no warnings, errors, or unexpected output.

### Test Command Conventions

- **Full test suite**: `carton exec prove -lr t/` (or `make test`)
- **Single test file**: `carton exec prove -lv t/path/to/test.t`
- **CRITICAL**: Always use `-lr` flags, NEVER use `-r` alone
  - `-l` adds `lib/` to @INC for proper module loading
  - `-r` alone causes absolute paths that break the `-l` behavior
- **Before workflow tests**: Always run `carton exec ./registry workflow import registry`
  - Workflow tests will fail silently if workflows not imported
  - This is the #1 most frequently forgotten step

### Common Test Failures and Solutions

**1. "Can't locate Registry/DAO/Foo.pm"**
- **Cause**: @INC path issue, using `prove -r` instead of `prove -lr`
- **Solution**: Ensure using `carton exec prove -lr t/` or `prove -lv` for single files

**2. "Workflow not found" or workflow tests failing mysteriously**
- **Cause**: Workflows not imported to database after YAML changes
- **Solution**: Run `carton exec ./registry workflow import registry`
- **Prevention**: Always import after editing any file in `workflows/`

**3. Schema detection failure in DAO classes**
- **Cause**: Wrong database schema in multi-tenant code
- **Solution**: Check for correct schema usage, use `isa` operator not `ref eq`

**4. UUID pattern match failures in tests**
- **Cause**: Incorrect regex pattern for UUID format
- **Solution**: Use `[\w-]+` not `\w+` for UUID patterns (need to match hyphens)

**5. PostgreSQL schema name errors**
- **Cause**: Schema names with hyphens (not allowed in PostgreSQL)
- **Solution**: Replace hyphens with underscores in schema names

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
  - **Test-only infrastructure belongs in `t/lib/` files** - NEVER add test-specific methods or infrastructure to core production classes. Test helpers, mocks, and specialized test infrastructure should be isolated in the test directory structure.
- **Template Extension**: Templates can specify a different workflow layout via `extends 'layouts/workflow'`

### Workflow Development Gotchas

**CRITICAL: Workflow Import Requirement**

After editing any workflow YAML file, you MUST run:
```bash
carton exec ./registry workflow import registry
```

- Workflow tests will fail silently if workflows not imported to database
- This is the #1 most frequently forgotten step (82% of development sessions)
- Workflow import errors are often YAML syntax issues (check indentation)
- Custom workflow steps live in `lib/Registry/DAO/WorkflowSteps/`
- Test workflows using `Registry::WorkflowProcessor->new_run($workflow, $data)`

**Workflow Development Cycle:**
1. Edit workflow YAML in `workflows/` directory
2. Import workflow: `carton exec ./registry workflow import registry`
3. Run workflow tests to verify functionality
4. Fix issues in YAML or custom workflow step classes
5. **Re-import workflow** (don't forget this step!)
6. Retest until passing
7. Commit YAML and any custom step classes together

### Database Migration Workflow

**Sqitch Migration Steps:**

1. **Create migration**: `carton exec sqitch add [name] -n "Description"`
2. **Write deploy SQL**: Edit `sql/deploy/[name].sql`
3. **Write revert SQL**: Edit `sql/revert/[name].sql`
4. **Write verify SQL**: Edit `sql/verify/[name].sql`
5. **Deploy**: `carton exec sqitch deploy`
6. **Import workflows** (if workflow steps changed): `carton exec ./registry workflow import registry`
7. **Run tests**: `carton exec prove -lr t/`
8. **Commit**: Commit migration files and code changes together

**Common Sqitch Issues:**
- **Deploy to wrong database**: Ensure correct database name in `sqitch.conf`
- **Foreign key violations**: Check migration dependency order in `sqitch.plan`
- **Verify failures**: Ensure verify SQL matches actual deployed schema

### Important Notes

- **Pre-Alpha System**: Registry is pre-alpha with no users yet. Do NOT worry about backwards compatibility unless explicitly told otherwise. Make the best technical decisions for the current codebase.
- **100% Test Pass Rate**: ALL tests must pass at 100% before any code changes are considered complete. This is non-negotiable.
- **Test Infrastructure Isolation**: Test-only infrastructure must be isolated in `t/lib/` files, never in core production classes. For example, workflow testing should use the real `Registry::WorkflowProcessor` or individual workflow step classes, not fake compatibility layers in production code.
- The workflow processor (`lib/Registry/Utility/WorkflowProcessor.pm`) handles workflow execution
- Custom workflow steps must inherit from base step classes and implement required methods
- HTMX attributes are used extensively for dynamic behavior without full page reloads
- **Workflow Testing**: Use the real production interfaces for testing workflows:
  - **Integration tests**: `Registry::WorkflowProcessor->new_run($workflow, $data)`
  - **Unit tests**: Individual workflow step classes like `Registry::DAO::WorkflowSteps::AccountCheck->process($db, $form_data)`
  - **Reference pattern**: See `t/dao/payment-workflow-step.t` for proper workflow testing approach

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
