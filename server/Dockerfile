# Multi-stage build for drome-server (plan.md tech stack: "build the musl
# binary"). Build context is the REPO ROOT (drome-server depends on ../core via
# a path dependency), so build with:  docker build -f server/Dockerfile .
#
# Stage 1 produces an x86_64 musl binary; stage 2 is a musl-native alpine runtime
# (ships curl for the HEALTHCHECK). The binary links against musl's loader
# (/lib/ld-musl-x86_64.so.1), so the runtime MUST be musl — a glibc image
# (debian-slim) lacks that loader and the server fails with
# "exec /usr/local/bin/drome-server: no such file or directory".

# ---- Stage 1: build ----
FROM rust:1.96-bookworm AS build

# musl target + a musl C toolchain (rusqlite `bundled` compiles SQLite from C,
# and ring — via ureq's rustls — needs a C compiler too).
RUN rustup target add x86_64-unknown-linux-musl \
    && apt-get update \
    && apt-get install -y --no-install-recommends musl-tools \
    && rm -rf /var/lib/apt/lists/*

ENV CC_x86_64_unknown_linux_musl=musl-gcc \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc

WORKDIR /app
# Copy the whole workspace (the root .cargo/config.toml pins target-dir to
# core/target for the whole workspace; .dockerignore keeps host artifacts out).
COPY . .

# --locked: build exactly the committed Cargo.lock. The C deps (bundled SQLite)
# link this dynamically against musl, so the runtime image below is musl-native.
RUN cargo build --release --locked --target x86_64-unknown-linux-musl -p drome-server \
    && cp core/target/x86_64-unknown-linux-musl/release/drome-server /drome-server

# ---- Stage 2: runtime ----
# musl-native runtime so the musl-linked binary's loader (/lib/ld-musl-x86_64.so.1)
# is present. curl is for the HEALTHCHECK; ca-certificates for the Apple JWKS fetch.
FROM alpine:3.20 AS runtime

RUN apk add --no-cache ca-certificates curl \
    && adduser -D -u 10001 -h /home/drome drome

COPY --from=build /drome-server /usr/local/bin/drome-server

USER drome
WORKDIR /home/drome

# Overridden by compose in production (DROME_DB points at the mounted volume).
ENV DROME_BIND=0.0.0.0:8080
EXPOSE 8080

# Real health probe: /healthz runs a query under the DB lock (docs/PHASE2.md).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/drome-server"]
