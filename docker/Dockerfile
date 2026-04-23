# syntax=docker/dockerfile:1.6

# -------- Stage 1: builder --------
FROM ubuntu:22.04 AS builder

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

RUN mkdir -p build \
    && cd build \
    && cmake ../xmrig \
    && make -j"$(nproc)" \
    && strip xmrig

# -------- Stage 2: runtime --------
FROM ubuntu:22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libuv1 \
        libssl3 \
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
    && useradd -r -s /bin/false xmrig \
    && chown -R xmrig:xmrig /app

USER xmrig

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
