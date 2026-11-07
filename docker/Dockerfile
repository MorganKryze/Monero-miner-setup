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

# FindUV in xmrig takes libuv.a first, and libuv1-dev on 26.04 ships one: link the
# shared libuv instead, so the miner loads the runtime libuv1t64 and gets its updates.
RUN cmake -S xmrig -B build -DUV_LIBRARY="/usr/lib/$(gcc -dumpmachine)/libuv.so" \
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

# Root owns the miner and its scripts, so the account that runs them cannot replace them for a
# later start; it writes only its config and log directories.
RUN mkdir -p /app/logs /app/configs \
    && chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /app/xmrig \
    && groupadd -r -g 999 xmrig \
    && useradd -r -u 999 -g xmrig -s /bin/false xmrig \
    && chown xmrig:xmrig /app/logs /app/configs

# Numeric so the host can resolve it; 999 is the id the image already used,
# so an existing ./logs volume stays writable.
USER 999:999

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
