# Contributing to Registry

Thank you for your interest in contributing to Registry! This document provides guidelines and instructions for setting up a development environment and contributing to the project.

## Table of Contents

- [Development Environment Setup](#development-environment-setup)
- [Project Architecture](#project-architecture)
- [Development Workflow](#development-workflow)
- [Testing](#testing)
- [Code Style](#code-style)
- [Submitting Changes](#submitting-changes)
- [Getting Help](#getting-help)

## Development Environment Setup

### Prerequisites

**Required:**
- Perl 5.40.2 or later
- PostgreSQL 12+ 
- Git
- cpanm (Perl package manager)

**Optional but Recommended:**
- Docker and Docker Compose (for containerized development)
- carton (Perl dependency manager)
- plenv or perlbrew (Perl version management)

### Quick Start with Docker

The fastest way to get started is using Docker:

```bash
# Clone the repository
git clone https://github.com/perigrin/Registry.git
cd Registry

# Start development environment
docker-compose up -d

# The application will be available at http://localhost:3000
```

### Manual Setup

#### 1. Install System Dependencies

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install -y \
    postgresql postgresql-contrib \
    libpq-dev \
    build-essential \
    libargon2-dev \
    pkg-config \
    curl \
    git
```

**macOS:**
```bash
brew install postgresql libpq libargon2 pkg-config
```

#### 2. Install Perl Dependencies

```bash
# Install carton (recommended)
cpanm Carton

# Install project dependencies
carton install
```

#### 3. Database Setup

```bash
# Start PostgreSQL service
sudo systemctl start postgresql  # Linux
brew services start postgresql   # macOS

# Create database and user
sudo -u postgres psql -c "CREATE DATABASE registry;"
sudo -u postgres psql -c "CREATE USER registry_user WITH PASSWORD 'password';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE registry TO registry_user;"

# Set database URL
export DB_URL="postgresql://registry_user:password@localhost/registry"

# Deploy database schema
carton exec sqitch deploy

# Import initial data
carton exec ./registry workflow import registry
carton exec ./registry template import registry
```

#### 4. Environment Configuration

Create a `.env` file (or set environment variables):

```bash
# Database
DB_URL=postgresql://registry_user:password@localhost/registry

# Application
MOJO_MODE=development
REGISTRY_SECRET=your-secret-key-for-development

# Optional: Stripe (for payment testing)
STRIPE_PUBLIC_KEY=pk_test_...
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...

# Email (for testing)
EMAIL_FROM=dev@localhost
SUPPORT_EMAIL=support@localhost
```

#### 5. Start Development Server

```bash
# Start with auto-reload
carton exec morbo ./registry

# Or use the make target
make dev-server

# Application available at http://localhost:3000
```

### Development Tools

#### Essential Commands

```bash
# Run all tests
make test
# or
carton exec prove -lr t/

# Run specific test
carton exec prove -lv t/dao/workflows.t

# Reset database (useful during development)
make reset

# Deploy only database migrations
carton exec sqitch deploy

# Start background job worker
carton exec ./registry minion worker

# Check application routes
carton exec ./registry routes
```

#### Code Quality Tools

```bash
# Check Perl syntax
perl -c lib/Registry.pm

# Run perltidy (if installed)
perltidy lib/Registry.pm

# Check test coverage (if Devel::Cover installed)
cover -test
```

## Project Architecture

Registry is built using modern Perl practices:

### Core Technologies
- **Framework**: Mojolicious web framework
- **Database**: PostgreSQL with Mojo::Pg ORM
- **Frontend**: HTMX for dynamic interactions
- **OOP**: Object::Pad for modern Perl classes
- **Jobs**: Minion for background processing
- **Migrations**: Sqitch for database versioning

### Directory Structure

```
Registry/
├── lib/Registry/           # Application code
│   ├── Controller/         # Web request handlers
│   ├── DAO/               # Data access objects
│   │   └── WorkflowSteps/ # Custom workflow step logic
│   └── Job/               # Background job processors
├── templates/             # HTML templates (Embedded Perl)
├── workflows/             # YAML workflow definitions
├── schemas/               # JSON Schema definitions
├── sql/                   # Database migrations (Sqitch)
├── t/                     # Test suite
│   ├── dao/              # Data layer tests
│   ├── controller/       # Web layer tests
│   ├── user-journeys/    # End-to-end scenarios
│   └── security/         # Security tests
└── public/               # Static assets (CSS, JS, images)
```

### Key Concepts

**Workflows**: The backbone of Registry. All user processes (registrations, event creation, etc.) are implemented as multi-step workflows defined in YAML files.

**Multi-Tenancy**: Schema-based isolation allows multiple organizations to use the same application instance.

**Outcome Definitions**: JSON Schema-based form definitions that integrate with workflows for custom data collection.

## Development Workflow

### 1. Feature Development

```bash
# Create feature branch
git checkout -b feature/your-feature-name

# Make your changes
# ... edit code ...

# Run tests
make test

# Commit changes
git add .
git commit -m "feat: add your feature description"

# Push to GitHub
git push origin feature/your-feature-name
```

### 2. Database Changes

When adding database changes:

```bash
# Create new migration
carton exec sqitch add your-migration-name

# Edit the migration files:
# - sql/deploy/your-migration-name.sql (schema changes)
# - sql/revert/your-migration-name.sql (rollback changes)
# - sql/verify/your-migration-name.sql (verification)

# Deploy locally
carton exec sqitch deploy

# Test migration
carton exec sqitch revert
carton exec sqitch deploy
```

### 3. Adding New Workflow Steps

```bash
# Create new workflow step class
# lib/Registry/DAO/WorkflowSteps/YourNewStep.pm

# Follow the pattern:
use 5.40.2;
use experimental 'signatures';
use Object::Pad;

class Registry::DAO::WorkflowSteps::YourNewStep :isa(Registry::DAO::WorkflowStep) {
    method process ($db, $form_data) {
        # Your logic here
        return { next_step => 'next-step-id' };
    }
    
    method template { 'path/to/template' }
}

# Create corresponding template
# templates/path/to/template.html.ep

# Add tests
# t/dao/workflow-steps/your-new-step.t
```

## Testing

Registry has comprehensive test coverage across multiple layers:

### Test Categories

- **Unit Tests**: `t/dao/` - Data access object tests
- **Controller Tests**: `t/controller/` - Web request handler tests  
- **Integration Tests**: `t/integration/` - Cross-component tests
- **User Journey Tests**: `t/user-journeys/` - End-to-end scenarios
- **Security Tests**: `t/security/` - Input validation and attack prevention

### Running Tests

```bash
# All tests
make test

# Specific test file
carton exec prove -lv t/dao/workflows.t

# Test with coverage (if Devel::Cover installed)
cover -test -report html_basic

# Security tests only
carton exec prove -lr t/security/

# User journey tests
carton exec prove -lr t/user-journeys/
```

### Writing Tests

Follow existing test patterns:

```perl
use 5.40.2;
use Test::More;
use Test::Mojo;
use lib 't/lib';
use Test::Registry::DB;

# Set up test database
Test::Registry::DB::new_test_db(__PACKAGE__);

# Your test code here
subtest 'Test description' => sub {
    # Test implementation
};

done_testing;
```

## Code Style

### Perl Style Guidelines

- **Modern Perl**: Use Perl 5.40.2+ features
- **Object::Pad**: Use for all new classes
- **Signatures**: Use subroutine signatures (`sub foo ($arg) { ... }`)
- **Experimental Features**: `use experimental qw(signatures try);`

### Code Patterns

**DAO Classes:**
```perl
use 5.40.2;
use experimental 'signatures';
use Object::Pad;

class Registry::DAO::YourClass :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $name :param :reader;
    
    use constant table => 'your_table';
    
    method your_method ($arg) {
        # Implementation
    }
}
```

**Controller Classes:**
```perl
use 5.40.2;
use Object::Pad;

class Registry::Controller::YourController :isa(Registry::Controller) {
    method your_action {
        # Handle request
        $self->render(template => 'your/template');
    }
}
```

### Template Guidelines

- Use semantic HTML5
- Include ARIA labels for accessibility
- Use HTMX attributes for dynamic behavior
- Follow existing CSS class patterns

## Submitting Changes

### Pull Request Process

1. **Fork the repository** on GitHub
2. **Create a feature branch** from `main`
3. **Make your changes** following the guidelines above
4. **Add or update tests** for your changes
5. **Ensure all tests pass** (`make test`)
6. **Update documentation** if needed
7. **Commit with clear messages** following conventional commits
8. **Push to your fork** and create a pull request

### Commit Message Format

Follow conventional commits:

```
type(scope): description

- feat: new feature
- fix: bug fix  
- docs: documentation changes
- test: adding or updating tests
- refactor: code restructuring
- perf: performance improvements
```

### Pull Request Guidelines

- **Clear title and description**
- **Reference related issues** (#123)
- **Include test coverage** for new functionality
- **Update documentation** as needed
- **Keep changes focused** - one feature per PR
- **Respond to feedback** promptly

## Getting Help

### Resources

- **Documentation**: Check `docs/` directory
- **Examples**: Look at existing code patterns
- **Tests**: Review test files for usage examples

### Support Channels

- **Issues**: GitHub Issues for bugs and feature requests
- **Discussions**: GitHub Discussions for questions
- **Email**: Technical questions to maintainers

### Development Tips

- **Start small**: Begin with documentation or test improvements
- **Ask questions**: Don't hesitate to ask for clarification
- **Read existing code**: Understand patterns before adding new code
- **Test thoroughly**: Include edge cases in your tests
- **Document changes**: Update relevant documentation

## Code of Conduct

Please be respectful and inclusive in all interactions. We welcome contributions from developers of all skill levels and backgrounds.

## License

By contributing to Registry, you agree that your contributions will be licensed under the same terms as the project (dual-licensed under GPL v1+ and Artistic License 1.0, same as Perl 5).

---

Thank you for contributing to Registry! Your help makes this project better for everyone.