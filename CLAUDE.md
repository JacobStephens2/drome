# Drome — app workspace

This directory is the build workspace for **Drome** (the 75 Hard–style tracker; the camel is also named Drome). If you are starting work here, read first:

1. `../phase-1-build-brief.md` — your mission, scope, environment constraints, and check-in points. Start there.
2. `../decisions.md` — canonical decision log.
3. `../plan.md` — the full plan; Phase 1 scope is the "MVP — Phase 1" section.

Hard rules that survive any context loss:

- **Phase 1 = iOS local-first MVP only.** No server, no accounts, no payments, no analytics.
- **Flexible mode is the default; purist (rules-as-written) mode is opt-in.**
- **Never put "75 Hard" in the app name, bundle ID, or store metadata** (third-party registered trademark).
- **This machine runs Santa in LOCKDOWN:** no `brew`, no unsigned host binaries. Rust builds happen in Docker by default; host rustup for iOS targets may need an admin allowlist first (see the brief). Docker images are per-user.
- The repo is **private**. Stack: Rust core (UniFFI) + native SwiftUI, monorepo (`core/`, `ios/`).

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
- Core: `cd core && cargo test`. Bindings + sim static lib: `core/build-ios-lib.sh`.
  App: `xcodebuild -project ios/Drome.xcodeproj -scheme Drome -destination 'platform=iOS
  Simulator,name=Chart35iPhone' build` (use a private -derivedDataPath when building in
  parallel with other agents).
- Bundle IDs: `day.drome.app` / `day.drome.app.widget`; App Group `group.day.drome.app`.
