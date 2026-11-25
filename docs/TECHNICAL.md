# Registry - Technical Overview and Development Guide

## System Architecture

Registry is a robust, extensible platform for after-school program management,
designed with flexibility and maintainability in mind.

### Technical Specifications
- **Core Language**: Perl 5.42 with Object::Pad feature classes
- **Web Framework**: Mojolicious
- **Database**: PostgreSQL with Mojo::Pg
- **Authentication**: Multi-layer security (Crypt::Passphrase)
  - Argon2 and Bcrypt password hashing
- **Frontend Interactions**: HTMX for lightweight, dynamic interfaces

## Deployment Options

### Local Development
```bash
# Clone the repository
git clone https://github.com/Tamarou/Registry.git
cd Registry

# Install dependencies
cpanm --installdeps .

# Database setup
sqitch deploy
morbo registry  # Development server

# Testing
make test
```

### Containerized Deployment
```bash
# Build Docker container
docker build -t registry .

# Run container
docker run -p 3000:3000 \
    -e DATABASE_URL=postgresql://user:pass@host/registry \
    registry
```

## Development Workflow

### Key Directories
- `lib/`: Core application logic
- `schemas/`: Database schema definitions
- `sql/`: SQL migration scripts
- `t/`: Comprehensive test suite
- `templates/`: HTMX-powered views
- `bin/`: Utility scripts

### Extension Points
- Customizable workflow templates
- Pluggable authentication mechanisms
- Flexible database schema
- Extensible Mojolicious plugins

## Contributing

### Development Guidelines
- Follow Perl best practices
- Maintain high test coverage
- Use Object::Pad feature classes
- Comprehensive documentation required

### Testing
- Full test suite with `prove`
- CI/CD integration via GitHub Actions
- Code coverage tracking

## System Requirements
- Perl 5.42+
- PostgreSQL 12+
- Docker (optional)

## Performance Considerations
- Efficient Perl data structures
- Minimal JavaScript footprint
- Optimized database queries
- Caching mechanisms implemented

## Monitoring and Maintenance
- Structured JSON logging
- Performance metric collection
- Easy backup and migration paths

### Recurring jobs
Minion has no cron, so each sweep recurs by queueing its own next run.
The sweeps and their intervals live in one table in
`lib/Registry/Job/Recurring.pm`: `attendance_check` (60s),
`domain_verification` (900s), `expire_entitlements` (300s),
`send_notifications` (300s),
`instalment_reconcile` (3600s), `waitlist_expiration` (300s) and
`process_waitlist` (600s).

- `setup_recurring_jobs` only seeds each chain at server start.
- After every run, whether it finished, failed or died, the job queues its
  next run with its interval, unless one is already queued. A restart, a
  second app process or a manual `./registry minion job -e <task>` never
  starts a second chain.
- Each run gets one attempt: the next run is the retry.
- Each sweep covers every tenant, the platform tenant (`registry`) included,
  exactly once per run (`t/job/recurring-sweeps-cover-platform.t`).
  `domain_verification` reads the platform's `tenant_domains` table, which
  holds every tenant's domains; `instalment_reconcile` covers each tenant
  whose row names a Stripe account. The per-tenant sweeps finish with
  `tenants_covered` and `tenants_skipped` (slug and error) in the job
  result: a tenant whose schema fails, or does not exist, is reported there
  and the sweep goes on to the rest. `expire_entitlements` also reports,
  under `expired`, the ids it expired in each tenant.

Check a chain with `./registry minion job -t <task> -S inactive`. One queued
job per sweep is healthy. None means the chain has stopped, and the next
server start reseeds it.

## Licensing
Open-source under Perl 5 licensing terms.
Contributions welcome via GitHub pull requests.

## Getting Deeper
1. Explore [architectural documentation](architecture/), starting with the
   [PriceOps model](architecture/priceops-model.md) before adding a product
2. Review [workflow schemas](../schemas/)
3. Check [development workflows](../workflows/)

## Contact
Technical support and development inquiries:
- GitHub Issues
- Developer mailing list
