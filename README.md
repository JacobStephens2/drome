# Drome

A free, local-first iOS tracker for 75-day challenges. The camel is also named Drome —
filling Drome the camel is using Drome the app.

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
