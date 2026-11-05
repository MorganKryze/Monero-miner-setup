# syntax=docker/dockerfile:1.6

# -------- Stage 1: builder --------
FROM ubuntu:26.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        libuv1-dev \
        libssl-dev \
        libhwloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY dependencies/xmrig ./xmrig

RUN cmake -S xmrig -B build \
    && cmake --build build -j"$(nproc)" \
    && strip build/xmrig

# -------- Stage 2: runtime --------
FROM ubuntu:26.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libuv1t64 \
        libssl3t64 \
        libhwloc15 \
        procps \
        jq \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /src/build/xmrig /app/xmrig
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN mkdir -p /app/logs /app/configs \
    && chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /app/xmrig \
    && groupadd -r -g 999 xmrig \
    && useradd -r -u 999 -g xmrig -s /bin/false xmrig \
    && chown -R xmrig:xmrig /app

# Numeric so the host can resolve it; 999 is the id the image already used,
# so an existing ./logs volume stays writable.
USER 999:999

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
