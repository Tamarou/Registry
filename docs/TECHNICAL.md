# Registry - Technical Overview and Development Guide

## System Architecture

Registry is a robust, extensible platform for after-school program management,
designed with flexibility and maintainability in mind.

### Technical Specifications
- **Core Language**: Perl 5.40 with Object::Pad feature classes
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
prove -lr t/
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
- Perl 5.40+
- PostgreSQL 12+
- Docker (optional)

## Performance Considerations
- Efficient Perl data structures
- Minimal JavaScript footprint
- Optimized database queries
- Caching mechanisms implemented

## Monitoring and Maintenance
- Built-in logging
- Performance metric collection
- Easy backup and migration paths

## Licensing
Open-source under Perl 5 licensing terms.
Contributions welcome via GitHub pull requests.

## Getting Deeper
1. Explore [architectural documentation](architecture/)
2. Review [workflow schemas](../schemas/)
3. Check [development workflows](../workflows/)

## Contact
Technical support and development inquiries:
- GitHub Issues
- Developer mailing list
