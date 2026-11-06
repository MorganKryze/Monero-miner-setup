#!/bin/bash
# The published image's Dockerfile: its parser directives, every line but comments and blanks,
# continuation lines included (a new RUN, ADD, COPY or USER, or one more command in a RUN,
# fails here), both stages on one Ubuntu tag, the two package lists, the apt-get install lines
# and the cmake line that links the shared libuv, so the miner loads the runtime's libuv1t64.
# A bump of the Ubuntu tag or of the official frontend's version passes; any other change
# updates this file with it.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
f=docker/Dockerfile
# Line 1 picks the frontend that turns this file into the build, so it names the official one;
# the blank line 2 ends directive parsing, so a `# check=` or `# escape=` after it is a comment.
first=$(sed -n 1p "$f") second=$(sed -n 2p "$f")
[ -z "$second" ] && printf '%s\n' "$first" | grep -qxE '# syntax=docker/dockerfile:[0-9]+(\.[0-9]+)*' \
  || { echo "FAIL parser directives: line 1 '$first', line 2 '$second'"; rc=1; }
tags=$(sed -nE 's/^FROM ubuntu:([0-9]{2}\.04) AS (builder|runtime)$/\1/p' "$f" | sort -u)
[ "$(grep -c '^FROM ' "$f")" -eq 2 ] && [ "$(printf '%s\n' "$tags" | grep -c .)" -eq 1 ] \
  || { echo "FAIL two stages on one ubuntu:NN.04 tag: $(grep '^FROM ' "$f" | xargs)"; rc=1; }
want=$(cat <<'DOCKERFILE'
FROM ubuntu:<tag> AS builder
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
RUN cmake -S xmrig -B build -DUV_LIBRARY="/usr/lib/$(gcc -dumpmachine)/libuv.so" \
    && cmake --build build -j"$(nproc)" \
    && strip build/xmrig
FROM ubuntu:<tag> AS runtime
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
USER 999:999
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
DOCKERFILE
)
got=$(grep -vE '^[[:space:]]*(#|$)' "$f" | sed 's/^FROM ubuntu:[0-9][0-9]\.04 AS /FROM ubuntu:<tag> AS /')
[ "$got" = "$want" ] || { echo "FAIL lines"; diff <(echo "$want") <(echo "$got"); rc=1; }
# Every apt-get call: the two update-and-install runs, as written, nothing else.
want=$(printf '%s\n' 'RUN apt-get update \' '    && apt-get install -y --no-install-recommends \' \
  'RUN apt-get update \' '    && apt-get install -y --no-install-recommends \')
got=$(grep -E 'apt(-get)? ' "$f")
[ "$got" = "$want" ] || { echo "FAIL apt-get lines"; diff <(echo "$want") <(echo "$got"); rc=1; }
packages() { # stage: the package lines of that stage's install run
  sed -n "/^FROM ubuntu:[0-9][0-9]\.04 AS $1\$/,/rm -rf \/var\/lib\/apt\/lists/p" "$f" \
    | sed -n 's/^        \([a-z0-9.+-]*\) \\$/\1/p' | xargs
}
want='build-essential cmake git libuv1-dev libssl-dev libhwloc-dev'
[ "$(packages builder)" = "$want" ] || { echo "FAIL builder packages: $(packages builder)"; rc=1; }
want='ca-certificates libuv1t64 libssl3t64 libhwloc15 procps jq netcat-openbsd'
[ "$(packages runtime)" = "$want" ] || { echo "FAIL runtime packages: $(packages runtime)"; rc=1; }
[ "$rc" -eq 0 ] && echo "PASS image-pins"
exit "$rc"
