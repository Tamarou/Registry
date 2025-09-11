FROM perl:5.40.2

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

# Install carton globally
RUN cpanm --notest Carton

# Set working directory
WORKDIR /app

# Copy cpanfile for dependencies (exclude test dependencies)
COPY cpanfile cpanfile.snapshot ./

# Create production cpanfile without test dependencies
RUN grep -v "Test::" cpanfile > cpanfile.prod \
  && mv cpanfile.prod cpanfile

# Install dependencies
RUN carton install --deployment

# Copy application code
COPY . .

# Copy and set up entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Create production registry script without local::lib
RUN sed 's/use local::lib/#use local::lib/' registry > registry.prod \
  && mv registry.prod registry \
  && chmod +x registry

# Set environment variables
ENV MOJO_MODE=production
ENV PERL5LIB=/app/lib
ENV PORT=5000

# Create storage directory and set permissions
RUN mkdir -p /app/storage \
  && chmod 755 /app/storage

# Create non-root user
RUN useradd -m -u 1001 registry \
  && chown -R registry:registry /app
USER registry

# Expose port
EXPOSE 10000

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:${PORT:-10000}/health || exit 1

# Use entrypoint script to determine service type
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
