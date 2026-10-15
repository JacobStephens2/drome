# Drome

A free, local-first tracker for 75-day challenges: two workouts, a gallon of water, ten
pages, a diet, no junk, and a progress photo, every day. Jerome the camel fills up as you
drink.

[drome.day](https://drome.day) · [iOS beta on TestFlight](https://testflight.apple.com/join/WrmejET1)

## Built for one real user

I built Drome for my sister. When she started her challenge, she was tracking it across a
Google Sheet, a separate water app that only logged in 16 oz steps, and a group chat full of
workout screenshots. She used Drome for her whole 75-day challenge.

Her habits set the design:

- **Flexible mode is the default.** Her group didn't restart from Day 1 after a missed day,
  and her "day" was her waking hours, which can run past midnight. Drome counts days the same
  way, with late-night logs landing on the right day. The core also has a strict,
  rules-as-written purist ruleset. It's opt-in and has no iOS UI yet.
- **Water in any amount.** You can pour any amount and set up container presets. A pace line
  tracks the day, and you get a warning if more than a liter goes in within an hour.
- **Catch-up is fast.** A backfill grid lets someone already partway through a challenge
  bring their history in within minutes.
- **Finishing a day should feel like something.** Completing a day triggers a real
  completion moment, and there's no confetti for partial credit.

The camel is named Jerome because she misheard "Drome," and the name stuck.

## What's here

| Path | What it is |
|---|---|
| [`core/`](core/) | Rust rules engine shared by every client through [UniFFI](https://mozilla.github.io/uniffi-rs/): an append-only event log, projections, flexible and purist rulesets, waking-hours day boundaries, and water pacing. Day-boundary math is property-tested. |
| [`ios/`](ios/) | Native SwiftUI app and an interactive WidgetKit water quick-add widget. The views handle presentation and OS integration, and the logic lives in the core. |
| [`server/`](server/) | Rust/Axum `drome-server`: Sign in with Apple and email sign-in, event sync, and friend groups. SQLite, replicated with Litestream. |
| [`infra/`](infra/), [`deploy/`](deploy/) | OpenTofu for a DigitalOcean droplet and Cloudflare DNS/R2, a Caddy + Litestream compose stack, and push-based GitOps deploys from GitHub Actions. |
| [`android/`](android/) | Kotlin/Compose phone and Wear OS clients over the same Rust core. |
| [`planning/`](planning/) | The original problem statement, plan, decision log, and research. |

The iOS app and its Rust core are what she used through her challenge. The server side
(accounts, sync, friend groups) and the Android and Wear OS clients are more experimental.

## Docs

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): the event schema, day attribution, core
  API, and design tokens. Start here.
- [`docs/PHASE2.md`](docs/PHASE2.md): the sync protocol, auth, groups, and infra/deploy.
- [`docs/ANDROID.md`](docs/ANDROID.md): the Android and Wear OS contract.
- [`planning/decisions.md`](planning/decisions.md): the decision log.

## Build

```sh
cargo test --workspace                # core rules engine + server
core/build-ios-lib.sh                 # Rust → simulator static lib + UniFFI Swift bindings
xcodebuild -project ios/Drome.xcodeproj -scheme Drome \
  -destination 'platform=iOS Simulator,name=<your simulator>' build
cargo run -p drome-server             # local server on :8080
```

See [`android/README.md`](android/README.md) for Android and [`infra/README.md`](infra/README.md)
for bootstrapping the production stack.

## License

[MIT](LICENSE). The vendored agent skills under `.agents/`, `.claude/`, and `.grok/` come
from [mattpocock/skills](https://github.com/mattpocock/skills) and carry that project's own
license.

---

Not affiliated with or endorsed by 75 HARD® or 44Seven Media. 75 HARD® is a registered
trademark of 44Seven Media, LLC.
