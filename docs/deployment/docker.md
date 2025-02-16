# Docker Deployment

This document covers deploying Registry using Docker.

## Basic Setup

```bash
# Clone the repository
git clone https://github.com/Tamarou/Registry.git
cd Registry

# Build and run the Registry container
docker build -t registry .
docker run -p 3000:3000 registry
```

## Environment Variables

Key environment variables that can be set when running the container:

- `PORT` - Port the application listens on (default: 3000)
- `DATABASE_URL` - PostgreSQL connection string
- `SESSION_SECRET` - Secret for session encryption

Example with environment variables:
```bash
docker run \
  -p 3000:3000 \
  -e DATABASE_URL=postgres://user:pass@host:5432/dbname \
  -e SESSION_SECRET=your-secret-here \
  registry
```

## Persistence

Registry requires a PostgreSQL database for persistence. You can either:
1. Connect to an existing PostgreSQL instance
2. Run PostgreSQL in a separate container
3. Use Docker Compose to manage both services

## Production Considerations

For production deployments, consider:
- Setting up proper logging
- Configuring backups
- Monitoring
- SSL/TLS termination
- Container orchestration

TODO: Expand these sections with specific recommendations and configurations.