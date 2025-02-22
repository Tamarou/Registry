FROM perl:5.40

# Install system dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    postgresql-client \
    libpq-dev \
    build-essential \
    git \
  && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy cpanfile for dependencies
COPY cpanfile cpanfile
COPY cpanfile.snapshot cpanfile.snapshot

# Install dependencies
RUN cpanm --installdeps --notest . \
  && cpanm App::Sqitch

# No need to create a script as we'll use the existing registry script from the repository

# Set environment variables
ENV MOJO_MODE=development
ENV PERL5LIB=/app/lib

# Command to run the application in development mode
CMD ["morbo", "-v", "/app/registry"]
