# Drome — app workspace

This directory is the build workspace for **Drome** (the 75 Hard–style tracker; the camel mascot is named **Jerome**). If you are starting work here, read first:

1. `../phase-1-build-brief.md` — your mission, scope, environment constraints, and check-in points. Start there.
2. `../decisions.md` — canonical decision log.
3. `../plan.md` — the full plan; Phase 1 scope is the "MVP — Phase 1" section.

Hard rules that survive any context loss:

- **Phase 1 = iOS local-first MVP only.** No server, no accounts, no payments, no analytics.
- **Flexible mode is the default; purist (rules-as-written) mode is opt-in.**
- **Never put "75 Hard" in the app name, bundle ID, or store metadata** (third-party registered trademark).
- **This machine runs Santa in LOCKDOWN:** no `brew`, no unsigned host binaries. Rust builds happen in Docker by default; host rustup for iOS targets may need an admin allowlist first (see the brief). Docker images are per-user.
- The repo is **public** — never commit personal data or secrets. Stack: Rust core (UniFFI) + native SwiftUI, monorepo (`core/`, `ios/`).

Build & contracts:

- **`docs/ARCHITECTURE.md` pins the Phase 1 contracts** (event schema, day attribution,
  core API, Swift facade, design tokens, file ownership). Read it before writing code.
- **Santa + cargo on this machine:** Santa Lockdown kills freshly-built host binaries,
  but the Lockdown profile (updated by Jacob 2026-07-04) allowlists execution from THIS
  repo's `core/target/(debug|release)/` — so plain `cargo test`/`build`/`clippy` work
  normally in `core/` with the default target dir (verified). Do NOT set a custom
  CARGO_TARGET_DIR outside the repo; a `signal: 9 SIGKILL` from a build tool means it
  executed from a non-allowlisted path. This covers crate build scripts for any
  `--target` (incl. device `aarch64-apple-ios`), since those always run from
  `core/target/{debug,release}/build/`.
- **Phase 2 workspace + server (`docs/PHASE2.md` is binding for `server/`):** the repo is
  now a Cargo workspace (`core` + `server`/`drome-server`). Root `.cargo/config.toml` pins
  `target-dir = core/target` for the WHOLE workspace so every freshly built binary — the
  server's test/bin artifacts included — executes from the Santa-allowlisted path. Plain
  `cargo test`/`clippy` in `core/` and `server/` both work (verified: a server test runs
  from `core/target/debug/deps/`). `server/.cargo/config.toml` (`target-dir = ../core/target`)
  is only consulted when cwd is `server/` and is kept in sync with the root config on
  purpose — if you edit one, edit both, or freshly built server binaries get SIGKILLed.
  Server dev loop: `cargo run -p drome-server` (listens on `0.0.0.0:8080`; envs `DROME_DB`,
  `DROME_BIND`, `BETA_ALL_ENTITLED`, and `DROME_DEV_AUTH=1` for local e2e — enables
  `POST /v1/auth/dev { account_key }` to mint a session without Sign in with Apple; NEVER
  set in production, where the route is unmounted/404). No Docker on this machine; CI builds
  the amd64 image.
- Core: `cd core && cargo test`. Bindings + sim static lib: `core/build-ios-lib.sh`.
  App: `xcodebuild -project ios/Drome.xcodeproj -scheme Drome -destination 'platform=iOS
  Simulator,name=Chart35iPhone' build` (use a private -derivedDataPath when building in
  parallel with other agents).
- DEBUG launch arg `-drome-demo-seed`: when the store has no challenge, seeds the demo fixture (Day 14 mid-challenge) through the real client.
- DEBUG launch arg `-drome-screen <water|workout|reading|history|settings|share>`: presents that screen on launch, for screenshots.
- Bundle IDs: `day.drome.app` / `day.drome.app.widget`; App Group `group.day.drome.app`.
