# Drome — Phase 4 Plan: Android (+ Wear OS)

Companion to ARCHITECTURE.md (Phase 1, binding for `core/` + `ios/`) and PHASE2.md
(binding for `server/`). This doc is the **plan** for the Android app; it is authored
ahead of Phase 4 and becomes binding the same way the others did — when Phase 4 starts,
if code and this doc disagree, bring the code back to the doc or change the doc in the
same commit. Product scope: plan.md "Phase 4: Android"; platform rationale:
`planning/research/what-would-make-a-hard75-app-useful.md` ("Platform strategy").
Revised 2026-07-20 per the adjudicated adversarial review
(`ANDROID-ADVERSARIAL-REVIEW.md`, rulings appended there).

## Goal

A native Android app at **feature parity with the iOS app as it stands at Phase 4
start** (Phase 1 local app + Phase 2 accounts/sync/groups), plus a Wear OS quick-add
app as the final milestone. Kotlin + Jetpack Compose over the same Rust core via
UniFFI's Kotlin bindings. No new product features invented on Android; parity first.
Mixed-platform friend groups are the point — an Android friend joins my sister's group and
sees exactly what an iOS member sees.

All Phase 1/2 guardrails carry over verbatim: no analytics, no calorie tracking, no
partial-credit celebration, photos on-device only and never in share cards, anti-chug
guard in all modes, flexible default / purist opt-in, honest labels, and **never "75
Hard" in the app name, application ID, or store metadata**.

## What carries over for free (the payoff of the Rust core)

- **All logic.** Rules engine (both modes), day attribution, streaks, water
  pacing/anti-chug, projections, backfill, export, and the entire sync module
  (idempotent event exchange, config LWW, reset epoch, one-active-challenge conflict)
  live in `drome-core` and are already property-tested. The Kotlin layer, like the
  Swift layer, is **views + OS integration only** (ARCHITECTURE.md principle 4 applies
  unchanged: if a composable is computing day logic, it's in the wrong layer).
- **The server.** The sync protocol is platform-agnostic by construction — events are
  uuid-keyed and additive, `device_id` is an arbitrary string, and nothing in
  `/v1/sync`, groups, or entitlements assumes Apple. Zero server changes for sync —
  and auth already works cross-platform (next section); the only genuinely new
  server work is the account-link endpoint.
- **Design + fixtures.** DesignSystem tokens (sand/ink/clay/camel/oasis, light/dark
  hex pairs), Jerome's vector assets, share-card layout, all copy, and the demo
  mock fixture (start 2026-06-21, days 1–12 complete, day 13 missing reading, day 14
  partial) port directly.
- **Portability proof.** `export_json` / `import_json` are platform-neutral: an iOS
  export restoring cleanly on Android (and vice versa) is a required acceptance test,
  not a nice-to-have.

## Auth: already cross-platform (adjudicated 2026-07-20)

An earlier draft assumed Phase 2 auth was Sign-in-with-Apple-only and gated Android
accounts on future magic-link work. That premise was stale: **email OTP is already
shipped** (`POST /v1/auth/email/request` + `POST /v1/auth/email/verify` — six-digit
code, resend cooldown, code hashed at rest; see `server/src/auth.rs`), the iOS app
already consumes it, and email identities live in the existing `account.apple_sub`
column as `email:<normalized-address>` (dev auth uses `dev:<key>`). Consequences:

- **Android signs in with email OTP against the existing endpoints, day one. No new
  server auth work gates the Android launch.**
- **Optional polish: Sign in with Google** — server verifies the Google ID token and
  extracts `sub`, parallel to the Apple JWKS flow. Only this work triggers the
  identity refactor below; skip both if OTP proves sufficient.
- **Identity refactor (only if a second token provider is added):** generalize
  `account.apple_sub` into `identity(account_id, provider, subject,
  UNIQUE(provider, subject))`. The migration must be **provider-aware** — parse the
  existing prefixes (`email:` → provider `email`, `dev:` → provider `dev`, everything
  else → provider `apple`); a blanket `provider='apple'` copy would misclassify email
  and dev accounts and strand them. Ship with a pre-migration inventory of
  `apple_sub` values, post-migration uniqueness checks, a rollback path, and tests
  over a fixture DB containing all three identity kinds. Deploy overlap is already
  sequenced by the existing migrate-at-startup single-writer design.

### Account linking (attach-first; merging is out of scope)

Same human, Apple on iPhone + email on Android. Two rules:

1. **Attach before create.** Android's sign-in screen offers "Already using Drome on
   iPhone?" *before* any account exists for this identity: the signed-in device
   displays a link code; the new device submits it with its freshly verified
   identity (`POST /v1/account/link`), which **attaches the identity to the existing
   account** — a second account is never created on this path. Link codes:
   single-use, short-TTL (≤5 min), hashed at rest, rate-limited, issued only by a
   recently-authenticated session.
2. **Populated-account merge is explicitly out of scope.** If the user already
   created and populated a second account, the two accounts stay two accounts,
   surfaced honestly ("this email is its own account — use export/restore to move
   data"). A real merge would have to reconcile event streams, `server_seq`
   allocation, config LWW, the one-active-challenge invariant, group memberships,
   entitlements, sessions, *and* every client's local binding to the numeric account
   id (iOS stores the local-data owner account id and keys the core sync context by
   it — `AppModel.swift`). That is a dedicated design if it's ever wanted, not an
   M4 side quest.

Linking is an **M4 acceptance criterion**, not an open question.

## Monorepo additions

```
android/
  settings.gradle.kts, gradle/libs.versions.toml, gradlew
  core/            :core — UniFFI bindings + Kotlin facade (no UI)
    src/main/kotlin/day/drome/core/
      Generated/   uniffi-bindgen kotlin output — do not hand-edit
      Models.kt DromeCoreClient.kt MockDromeCore.kt LiveDromeCore.kt SyncEngine.kt
    src/main/jniLibs/{arm64-v8a,x86_64}/libdrome_core.so   (build artifact, gitignored)
  app/             :app — phone app (Compose) + Glance widget
    src/main/kotlin/day/drome/app/
      DesignSystem.kt AppViewModel.kt ui/ widget/
  wear/            :wear — Wear OS app (final milestone)
core/build-android-lib.sh          sibling of build-ios-lib.sh
.github/workflows/android-ci.yml   path-filtered, like the others
```

- **applicationId `day.drome.app` for BOTH the phone and Wear artifacts** — the
  reverse-domain convention makes the existing bundle ID a valid Android application
  ID, and the Wearable Data Layer only connects phone and watch apps with **matching
  package names and signatures**, so the Wear app cannot take a `.wear` suffix.
  `:app` and `:wear` stay separate Gradle modules with their own manifests and
  form-factor declarations, ship through the same Play listing's phone and Wear
  release tracks, and share one signing lineage (Play App Signing).
- **minSdk 26; targetSdk pinned at kickoff to the Play requirement then in force**
  (API 35 today; API 36 required for updates after 2026-08-31, and Wear OS carries
  its own, separate target requirement — confirm both against current Play policy at
  M1, don't assume). minSdk 26 gives native `java.time` (no desugaring) and ~98%
  device coverage; nothing in the app needs newer.
- Kotlin 2.x, Compose BOM current-at-start, Material 3, single-activity, Glance for
  the widget, Compose for Wear OS. Version catalog in `libs.versions.toml`.

## Core bindings (UniFFI → Kotlin)

- `drome-core` already builds `cdylib`; uniffi 0.32's Kotlin bindgen is the same
  proc-macro pipeline the Swift bindings use. Add a `[bindings.kotlin]` section to
  `core/uniffi.toml` (package `day.drome.core.generated`).
- **`core/build-android-lib.sh`** mirrors `build-ios-lib.sh`: for each target
  (`aarch64-linux-android` for devices, `x86_64-linux-android` for the emulator)
  `cargo build --target … ` with the NDK clang wired up as linker via cargo config
  env (`CARGO_TARGET_<T>_LINKER` + `CC_<t>`/`AR_<t>`), then `cargo run --features cli
  --bin uniffi-bindgen -- generate --language kotlin` → `android/core/src/main/kotlin/
  day/drome/core/Generated/`, and copy the `.so`s into `jniLibs/`. **Deliberately no
  `cargo-ndk`**: plain cargo + explicit linker env keeps local and CI byte-identical
  with one less tool to install. (The original motivation was Santa — `~/.cargo/bin`
  wasn't allowlisted — which no longer applies; the simplicity argument stands on
  its own.)
  32-bit ABIs (`armeabi-v7a`) are skipped unless a real user surfaces on one.
- **16 KB page-size compliance is a package property, not a toolchain choice.** NDK
  r28+ (pinned in the script and CI) aligns *our* `.so`s by default, but every
  packaged native library must comply — including JNA's `libjnidispatch.so` and any
  later dependency's. Pin AGP ≥ 8.5.1 and a JNA version verified 16 KB-clean for the
  shipped ABIs, and gate releases in CI (see CI section): per-`.so` ELF
  program-header alignment sweep over the finished artifact, `zipalign -c -P 16` /
  bundletool inspection, plus one boot-and-log smoke run on a 16 KB emulator image.
- The generated Kotlin runtime requires **JNA** (`net.java.dev.jna:jna:…@aar`) — a
  `:core` implementation dependency.
- The Android `.so` is never executed on the host; crate build scripts run from
  `core/target/{debug,release}/build/` as usual. (Santa constraints on this no longer
  apply — see Toolchain spike.)

## Toolchain spike (M0) — Santa no longer applies

**Update 2026-07-20: Jacob's current dev Mac does not run Santa.** The original
version of this section planned a go/no-go allowlist audit of every Android host
binary (NDK clang, AAPT2, Gradle/JDK, emulator) against Santa LOCKDOWN; that audit
is moot — the full toolchain (Android Studio, SDK/NDK, emulator) installs and runs
normally. If development ever returns to a Santa-managed machine, resurrect the
audit table from this file's git history and follow the tofu SHA-pin precedent in
decisions.md.

M0 is therefore a plain toolchain sanity spike: install Android Studio + SDK + the
pinned NDK, `rustup target add aarch64-linux-android x86_64-linux-android`, run
`build-android-lib.sh` end-to-end, and finish with a hello-world Compose app calling
`DromeStore.open()` + `today()` against the real `.so` on an emulator.

CI (Linux) remains the **canonical** Android builder regardless — releases and the
16 KB gates run there, so local setup is convenience, never a release dependency.

## Kotlin layer contracts (mirror of the Swift layer, same rules)

- **`Models.kt`** — Kotlin-native mirrors of the core records (immutable data
  classes). Views use ONLY these types.
- **`DromeCoreClient.kt`** — interface mirroring the core API as **suspend funs**;
  implementations stamp `LocalInstant` internally from `ZonedDateTime.now()` (epoch
  secs + current UTC offset) — views never pass time, identical to iOS.
- **`MockDromeCore.kt`** — in-memory impl seeded with the same demo fixture; used by
  `@Preview`s, Paparazzi, and the feature fan-out build stage.
- **`LiveDromeCore.kt`** — maps Generated ↔ Models; **the only file (plus Generated/)
  that may import the bindings**. `DromeStore` is a `Mutex<Connection>` internally and
  its calls block — `LiveDromeCore` confines them to `Dispatchers.IO`; exactly one
  `DromeStore` instance per process.
- **`SyncEngine.kt`** — Kotlin twin of the iOS SyncEngine: moves JSON over OkHttp,
  stamps time, calls the core sync module via UniFFI. Opportunistic (foreground +
  after logs, debounced). Session tokens live in Keystore-backed encrypted storage —
  exact mechanism chosen at phase start (`EncryptedSharedPreferences` and the stable
  `security-crypto` artifact are deprecated with no successor releases; do not bind
  to them). Contract regardless of mechanism: access + refresh tokens replaced
  atomically as a pair; concurrent refresh attempts (sync, groups, entitlement,
  deletion) serialized through one gate; a missing or invalidated Keystore key
  degrades to a clean local sign-out, never any form of local-data reset; token
  material excluded from backup and device transfer. Fully functional signed-out.
- **`AppViewModel.kt`** — `@MainActor AppModel`'s twin: an `androidx` ViewModel owning
  a `DromeCoreClient`, exposing `TodayState`/`ChallengeSummary` as `StateFlow`, intent
  methods (logWater, logWorkout, …), and one-shot `pendingCompletionMoment` /
  `pendingChugWarning` events for the UI. Intent methods serialize through a single
  internal queue so two rapid suspend calls can never publish core results out of
  order and regress the visible state.
- **`DesignSystem.kt`** — tokens only here; no hex literals in feature composables.
  Same palette values as `Drome/DesignSystem.swift` (sand #F3EAD8/#1C1917, ink, clay
  #C2410C, camel #B45309, oasis #0E7490/#22D3EE, done, miss), mapped into a custom
  Material 3 `ColorScheme` + Drome-specific tokens for what M3 can't express. System
  font, black-weight tight-tracked headers, monospaced digits for counters, 48dp tap
  targets ("gear, not toy" survives the port).
- **`JeromeView`** — Compose Canvas port of `CamelView(fill, celebrating)` using
  Melissa's vector trace + the alpha silhouette for the water layers, behind the same
  stable API, including drag-up-to-pour / drag-down-to-correct.

## App architecture notes (where Android genuinely differs from iOS)

- **One process, one DB — with stateless entry points.** Glance code
  (`provideGlance`, `ActionCallback.onAction`) executes in the app's own process —
  the launcher only *hosts the rendering* — so there is no App Group analog: one
  `filesDir/drome.sqlite` (WAL), one lazily-initialized `DromeStore` singleton. But
  a widget tap can be the thing that *starts* that process: every widget entry point
  initializes the store on demand and never assumes a live Activity, ViewModel, or
  cached StateFlow. Widget mutations are one core transaction each, kept well inside
  receiver execution limits.
- **Widget (Glance):** camel fill + container-preset buttons; a tap logs through the
  same `LiveDromeCore` and pushes fresh state to the widget (the
  `WidgetCenter.reloadAllTimelines()` analog lives in this layer, never the core).
  The foreground board re-reads on ON_RESUME — same pattern as the iOS scene-phase
  refresh — so a widget write while the app is backgrounded is always picked up.
  Tests: rapid repeated taps, widget tap with the app process dead, app + widget
  interleaved logging.
- **OS backup: excluded, on every supported API level.** Two rule sets are required:
  `dataExtractionRules` (API 31+, covering both cloud backup and device-to-device
  transfer) **and** legacy `fullBackupContent` (API 26–30). `filesDir/drome.sqlite`
  is the **`file` domain** in those rules (the `database` domain only covers
  `getDatabasePath` files); exclude `drome.sqlite`, `drome.sqlite-wal`, and
  `drome.sqlite-shm` as a set (a partially restored WAL trio is silent corruption),
  plus sync state and token storage. Rationale: a system restore silently duplicates
  `device_id` + sync watermarks onto new hardware, and Drome already has first-class
  data safety. The M2 off-device backup mechanism, named: user-initiated SAF
  document export (Drive or any provider) with the same visible "last backed up"
  state as iOS. Test backup extraction on API ≤30 and API 31+ devices, plus
  uninstall/reinstall before any account exists.
- **Share card:** render the existing `share_card(date)` data with a dedicated
  composable → bitmap → system share sheet (story-sized, ruleset label, no photos —
  identical contract).
- **Photos:** CameraX/photo-picker attach into app-private storage; core stores only
  the ref string; delete orphaned files on `revoked_photo_refs`, same as iOS.
- **Reminders (Phase 2 parity) are inexact by design.** Deficit-driven reminders are
  coarse ("still open: 40 oz, reading"), so WorkManager / inexact alarms are the
  contract — Doze-delayed delivery by minutes is acceptable and the copy must read
  correctly when late. Drome does **not** assume `USE_EXACT_ALARM` (Play restricts
  it to alarm/timer/calendar apps, which Drome is not); if a genuinely precise
  feature ever appears (purist workout-spacing deadlines), it requests user-granted
  `SCHEDULE_EXACT_ALARM` and degrades gracefully when denied or revoked. Recompute +
  reschedule on: reboot, app update, timezone/clock change, waking-window edit, task
  completion, challenge reset. Deep-link into the logging action; the anti-chug copy
  rule ("never cheer late-night catch-up") applies verbatim. Test under
  Doze/battery-saver and DST/travel transitions.
- **Health Connect** (the HealthKit analog, and the research's explicit
  recommendation): workout auto-import — duration + a best-effort outdoor heuristic
  (exercise type; GPS-backed sessions) with manual override. Read-only, import-only,
  opt-in, mirroring the Phase 2 Apple Health scope.
- **App Links for group invites:** when invite links (`drome.day/j/<code>`) ship,
  Android link verification needs `assetlinks.json` served from
  `drome.day/.well-known/` — a small server/Caddy task, planned alongside the iOS
  universal-links AASA work. In-app code entry (the Phase 2 baseline) needs none of
  this.

## Wear OS (final milestone, parity with the Phase 3 watchOS scope)

Compose for Wear OS app + a **tile** for one-tap container logging, task check-off,
and camel fill at the wrist. v1 is **companion-only**: the phone owns the store; no
watch-side Rust, no standalone-watch sync — reevaluate only if real users demand
phone-free logging. Same applicationId and signing as the phone app (a Data Layer
hard requirement — see Monorepo additions).

**Durable delivery, not fire-and-forget.** `MessageClient` is best-effort and
connection-dependent, and a single shared DataItem path would coalesce rapid water
taps — unacceptable for an app whose cardinal rule is that progress cannot be lost.
The watch keeps a small persisted **outbox**: every tap becomes an immutable command
with its own UUID, written as its own DataItem (`/cmd/<uuid>`, delivered even when
written offline); the phone ingests idempotently (the core's uuid dedup makes
duplicate delivery a no-op), acks on a response path, and only an ack deletes the
outbox entry. The tile shows pending/delivered state honestly. Tests: phone
disconnected then reconnected, duplicate delivery, rapid repeated taps, watch
process death mid-outbox, phone replacement.

The purist 45-minute workout timer ports here only when purist UI exists on Android
at all.

## Testing

- **Core:** unchanged — `cd core && cargo test` covers both platforms' logic. This is
  the whole bet paying off; Android adds zero rules tests.
- **JVM-first Android testing** (fast, deterministic, no emulator in the loop):
  unit tests over `AppViewModel` + `MockDromeCore`; **Paparazzi** snapshot tests for
  every feature composable in light/dark (runs on the JVM, no device).
- **Bindings + mapping coverage:** a small instrumented (or Robolectric-with-jniLibs)
  suite exercises `LiveDromeCore` against the real `.so`; separately, the
  Generated↔Models mapping layer gets exhaustive JVM tests — every enum and error
  variant, optional fields, sync records, conflict results, numeric conversions. The
  mapping layer is handwritten twice (Swift, Kotlin); its tests are what keep the
  twins honest, and open/log/project/export alone does not exercise it.
- **Sync e2e:** `cargo run -p drome-server` with `DROME_DEV_AUTH=1` + the Android
  emulator (`http://10.0.2.2:8080` — the emulator's localhost alias) beside the iOS
  simulator: the standing two-device merge, conflict, and reset-epoch scenarios now
  run cross-platform.
- CI runs Paparazzi + unit tests on every android-path PR; the instrumented smoke
  suite runs on a Gradle-managed emulator in CI where practical.

## CI / release lane

- **`android-ci.yml`** (path-filtered on `android/`, `core/`): rustup Android targets
  + pinned NDK → `build-android-lib.sh` → `gradle test` (unit + Paparazzi) → assemble
  a debug APK artifact on PRs; on tags, bundle a signed AAB **and run the 16 KB
  release gates** (per-`.so` ELF alignment sweep, `zipalign -c -P 16`, bundletool
  inspection, 16 KB-emulator boot smoke). CI is canonical, local is convenience —
  release artifacts only ever come from CI.
- **Like iOS, Android release is not GitOps:** tag-driven CI in its own lane. Upload
  key in GitHub secrets; **Play App Signing** holds the real signing key from day one.

## Play Store

- **Play Console account for Stephens Page LLC** (organization account: $25 one-time,
  requires a D-U-N-S number — start this early, verification takes days-to-weeks; an
  org account also avoids the personal-account 12-tester/14-day closed-testing
  requirement). Owner-action item, like the Apple Developer ID was.
- Track ladder: **internal testing** (Jacob + any Android-carrying friend) → **closed
  testing** (the Android side of my sister's extended circle) → production at public
  launch, aligned with wherever iOS is by then.
- Listing: same trademark discipline — zero "75"+"Hard" in title/keywords; nominative
  "works with 75-day challenges…" phrasing only if counsel approved it for the App
  Store; same non-affiliation disclaimer. Data safety form: inventory the real
  surface, not the slogan — local-first with nothing collected by default, THEN:
  login email (account holders), synced challenge/fitness-adjacent data (opt-in),
  group display identity, purchases via RevenueCat/Play Billing at launch parity,
  and whatever any dependency collects (audit it; the answer should stay "nothing,"
  and the audit is what makes that claim honest).
- **Billing** (only at public-launch parity, free beta before): Google Play Billing
  via **RevenueCat** — already the plan-of-record so iOS StoreKit, Play Billing, and
  future Stripe/web resolve to one entitlement the server verifies. The server's
  entitlement gate doesn't change.

## Milestones

- **M0 — Toolchain spike.** Android Studio + SDK + pinned NDK + rustup targets
  installed; `build-android-lib.sh` produces a real `.so` + Kotlin bindings;
  hello-world Compose app calls `DromeStore.open()`/`today()` on an emulator. (The
  former Santa go/no-go audit is moot — see Toolchain spike section.)
- **M1 — Skeleton + contracts.** Gradle workspace, `:core` facade (Models/Client/
  Mock/Live), DesignSystem.kt, AppViewModel, CI green with Paparazzi baseline — and
  the **Phase 4 parity matrix frozen** (snapshot the actual iOS surface; "whatever
  iOS has then" stops being the scope definition). Confirm targetSdk/Wear target
  requirements against current Play policy here too.
- **M2 — Local parity.** Day board (six tiles, two workout slots), water + Jerome
  (pour/correct gestures, presets, pace, anti-chug, pour ledger), reading/diet/
  no-junk/photo, universal task toggling, completion moment, onboarding + backfill
  grid, settings/export/backup/restore, share card. **Acceptance:** an iOS
  `export_json` imports on Android and, on re-export, the **canonicalized importable
  subset** (challenge, presets, extras, events — the fields import actually reads;
  see `core/src/export.rs::Snapshot`) is equal; projections (`days`, `summary`) are
  compared separately at a fixed injected `LocalInstant`; `exported_at` and other
  generated metadata are asserted independently, never diffed. Photo policy:
  `photo_done` events restore the check-off; refs to files that never crossed
  devices resolve gracefully to "no attachment." Fixtures include revoked events,
  attached photos, goal changes, and sync-origin events — not just the demo happy
  path. The demo-fixture demo walks end-to-end.
- **M3 — Glance widget.** Interactive water quick-add; log-from-widget updates the
  board and vice versa.
- **M4 — Accounts, sync, groups.** Email OTP against the existing endpoints (no new
  server auth for launch); SyncEngine; group screen + nudges; **attach-first account
  linking** (link-code contract above — the only new server route). **Acceptance:
  the cross-platform two-device e2e suite passes against a local server; an Android
  member appears correctly in an iOS group (and vice versa) against drome.day; and a
  link-code attach followed by a sync round-trip lands the same challenge under both
  identities.**
- **M5 — Health Connect import + reminders parity.**
- **M6 — Play release lane.** Org account verified, signed AAB out of CI, internal →
  closed testing live on real devices.
- **M7 — Wear OS v1.** Tile + app, companion-only, durable-outbox protocol, same
  applicationId + signing as the phone app. **Acceptance: Data Layer connection
  smoke test on paired devices, plus the disconnect/duplicate/rapid-tap outbox
  suite.**

M0–M2 have no server dependency and can start any time after Phase 3; M4's server
work has shrunk to the account-link endpoint (email OTP already exists; the identity
refactor happens only if Google Sign-In is added).

## Open questions (decide at phase start)

- **Google Sign-In: worth the identity refactor?** Email OTP covers Android launch;
  add Google only if beta users balk at codes. The provider-aware migration above is
  the price of admission.
- **Paparazzi vs Roborazzi** for snapshots — whichever is healthier at phase start;
  the contract is "JVM snapshot tests, no emulator required," not the tool.
- **Tablet/foldable posture**: default to phone-layout-that-scales; no dedicated
  large-screen UI unless Play's form-factor review forces minimal fixes.

(Resolved by adjudication 2026-07-20, no longer open: second auth method — email OTP
already shipped; account-linking scope — attach-first, merge out of scope; parity
cut — frozen as a matrix at M1.)
