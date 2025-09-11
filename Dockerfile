# Build stage - install dependencies and build tools
FROM perl:5.40.2 AS builder

# Install system dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    postgresql-client \
    libpq-dev \
    build-essential \
    git \
    curl \
    libargon2-dev \
    pkg-config \
  && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy cpanfile for dependencies (exclude test dependencies)
COPY cpanfile cpanfile.snapshot ./

# Create production cpanfile without test dependencies and install directly to system
RUN grep -v "Test::" cpanfile > cpanfile.prod \
  && cpanm --notest --installdeps . --cpanfile cpanfile.prod

# Production stage - minimal runtime image
FROM perl:5.40.2

# Install only runtime dependencies (no build tools)
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    postgresql-client \
    libpq-dev \
    curl \
    libargon2-1 \
  && rm -rf /var/lib/apt/lists/*

# Copy installed Perl modules from builder stage
COPY --from=builder /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=builder /usr/local/share/perl5 /usr/local/share/perl5

# Set working directory
WORKDIR /app

# Copy application code
COPY . .

# Copy and set up entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Make registry script executable (dependencies already in system Perl)
RUN chmod +x registry

# Set environment variables
ENV MOJO_MODE=production
ENV PERL5LIB=/app/lib
ENV PORT=10000

# Create storage directory and set permissions
RUN mkdir -p /app/storage \
  && chmod 755 /app/storage

# Create non-root user
RUN useradd -m -u 1001 registry \
  && chown -R registry:registry /app
USER registry

# Expose port
EXPOSE 10000

# Health check handled by Render platform

# Use entrypoint script to determine service type
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
