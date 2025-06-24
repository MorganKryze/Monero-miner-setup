FROM ubuntu:22.04

# Set non-interactive mode for apt
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    libuv1-dev \
    libssl-dev \
    libhwloc-dev \
    git \
    curl \
    jq \
    netcat \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy project files
COPY . .

# Build XMRig
RUN mkdir -p build-xmrig && \
    cd build-xmrig && \
    cmake ../dependencies/xmrig && \
    make -j$(nproc) && \
    ln -sf /app/build-xmrig/xmrig /app/xmrig

# Create logs directory
RUN mkdir -p /app/logs

# Copy entrypoint and healthcheck scripts
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh

# Make scripts executable
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /app/xmrig

# Create non-root user for security
RUN useradd -r -s /bin/false xmrig

# Set ownership
RUN chown -R xmrig:xmrig /app

# Switch to non-root user
USER xmrig

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]