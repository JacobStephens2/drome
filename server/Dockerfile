# Multi-stage build for drome-server. Build context is the REPO ROOT
# (drome-server depends on ../core via a path dependency), so build with:
#   docker build -f server/Dockerfile .
#
# BOTH stages are Alpine/musl so the binary's libc matches exactly at runtime.
# History (don't reintroduce): a Debian glibc runtime lacked the musl loader
# entirely (exec: "no such file or directory"), and building on Debian's
# musl-tools then running on Alpine mismatched the musl VERSION and segfaulted
# at startup. Same-musl build+run avoids both.

# ---- Stage 1: build ----
FROM rust:1.96-alpine AS build

# C toolchain for the bundled SQLite (rusqlite `bundled` compiles SQLite from C)
# and ring (via ureq's rustls). Alpine's native musl gcc, so the compiled objects
# match the runtime musl.
RUN apk add --no-cache build-base

WORKDIR /app
# Copy the whole workspace (the root .cargo/config.toml pins target-dir to
# core/target for the whole workspace; .dockerignore keeps host artifacts out).
COPY . .

# rust:alpine's host target is x86_64-unknown-linux-musl (already installed), so
# this builds a musl binary matching the Alpine runtime below. --locked: build
# exactly the committed Cargo.lock.
RUN cargo build --release --locked --target x86_64-unknown-linux-musl -p drome-server \
    && cp core/target/x86_64-unknown-linux-musl/release/drome-server /drome-server

# ---- Stage 2: runtime ----
FROM alpine:3.20 AS runtime

# GHCR links this package to the repo only when the image carries this label.
# An unlinked package is private, and this repo's GITHUB_TOKEN then cannot
# push to that name (permission_denied: read_package).
LABEL org.opencontainers.image.source=https://github.com/JacobStephens2/drome

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
