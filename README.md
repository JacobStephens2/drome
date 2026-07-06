# Drome

A free, local-first iOS tracker for 75-day challenges. The camel is named **Jerome**
(rhymes with Drome — my sister misheard it and the name stuck). Filling Jerome is using Drome.

- **`core/`** — Rust: rules engine (flexible + purist rulesets), waking-hours day
  boundaries, append-only event log, projections, water pacing + anti-chug guard.
  Exposed to Swift via UniFFI.
- **`ios/`** — native SwiftUI app + WidgetKit water quick-add widget. Views and OS
  integration only; logic lives in the core.
- **`docs/ARCHITECTURE.md`** — pinned Phase 1 contracts (event schema, day attribution,
  API surface, design tokens). Start there.

Phase 1 is local-first and free: no server, no accounts, no payments, no analytics.
Bundle ID `day.drome.app`. Not affiliated with or endorsed by 75 HARD® / 44Seven Media.

## Build

```sh
cd core && cargo test                 # rules engine tests (same as CI)
core/build-ios-lib.sh                 # Rust → sim staticlib + UniFFI Swift bindings
xcodebuild -project ios/Drome.xcodeproj -scheme Drome \
  -destination 'platform=iOS Simulator,name=Chart35iPhone' build
```

## Phase 2 (server, sync, groups)

- **`server/`** — Rust/Axum `drome-server` (accounts, sync, groups). Dev loop:
  `cargo run -p drome-server`. Container: `server/Dockerfile` (built by CI, not locally).
- **`infra/`** — OpenTofu root module for the production DigitalOcean droplet + Cloudflare
  DNS/R2 (authored now, applied at the deploy milestone). Local check: `cd infra && tofu fmt`;
  `tofu validate` runs in `infra-ci.yml` (provider plugins are Santa-blocked on this Mac).
  See **`infra/README.md`** for the bootstrap runbook.
- **`deploy/`** — compose stack (drome-server + Caddy + Litestream), `Caddyfile`,
  `litestream.yml`, and the push-based `deploy.sh`.
- **`docs/PHASE2.md`** — Phase 2 contracts (sync protocol, auth, groups, infra & deploy).
