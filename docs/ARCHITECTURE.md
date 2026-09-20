# Drome — Phase 1 Architecture & Contracts

This file pins the shared contracts for the Phase 1 build. If code and this doc disagree
during Phase 1 bring the code back to the doc (or change the doc in the same commit, with
a note). Product scope lives in `../plan.md` (planning folder); this doc is only *how*.

## Monorepo layout

```
drome/
  CLAUDE.md                 workspace rules (Santa, scope, trademark)
  docs/ARCHITECTURE.md      this file
  core/                     Rust crate `drome-core` (rules engine, event log, storage)
    Cargo.toml
    src/
    build-xcframework.sh    builds DromeCore.xcframework + Swift bindings
  ios/
    Drome.xcodeproj/        hand-authored, objectVersion 77, synchronized groups
    Drome/                  app target source (folder-synchronized)
      Views/
      Assets.xcassets
    DromeShared/            source shared by app + widget targets
      Generated/            UniFFI output (dromeCore.swift) — do not hand-edit
    DromeWidget/            widget extension target source
    Frameworks/             DromeCore.xcframework (build artifact, gitignored)
  .github/workflows/core-ci.yml
```

- App bundle ID `day.drome.app`, widget `day.drome.app.widget`, App Group
  `group.day.drome.app`. Display name **Drome**. Deployment target **iOS 17.0**.
  `SWIFT_VERSION = 5.0`. Never put "75 Hard" in bundle IDs, product names, or metadata.
- The SQLite DB lives in the App Group container: `<group container>/drome.sqlite`
  (fallback: Application Support when the group container is unavailable, e.g. some
  simulator configs). WAL mode so app + widget can share it across processes.

## Core principles

1. **The core is clock-free and timezone-free.** Every API that needs "now" takes an
   explicit `LocalInstant { epoch_secs: i64, tz_offset_secs: i32 }` captured by the caller
   at call time. Local wall time = `epoch_secs + tz_offset_secs`. This makes day-boundary
   math deterministic and property-testable.
2. **Append-only event log.** No UPDATE/DELETE on the `events` table (enforced by SQLite
   triggers). Undo = a `Revoked { event_uuid }` event; projections skip revoked events.
   Day state is always a projection, never stored authoritatively.
3. **Rulesets are pluggable.** `Flexible` (default, fully implemented) and `Purist`
   (implemented in the core where cheap, **no UI in Phase 1**). One engine, two presets.
4. **The Swift layer is views + OS integration only.** All rules/date/streak/pacing logic
   lives in Rust. If a SwiftUI view is computing day logic, it's in the wrong layer.

## Time & day attribution (the heart — property-test this)

- Challenge config: `start_date` ("YYYY-MM-DD", may be in the past), `length_days` = 75,
  `day_cutoff_minutes` (minutes after midnight; default **240** = 4:00 AM),
  `waking_start_minutes` (default 420 = 7:00 AM), `waking_end_minutes` (default 1320 =
  22:00; used for water pacing only).
- **Attribution algorithm** for an event:
  1. If the event has an explicit `effective_date` → that date (retroactive logging,
     backfill).
  2. Else compute local wall clock from `logged_at`, subtract `day_cutoff_minutes`, take
     the calendar date. (A 1:30 AM log with a 4:00 AM cutoff belongs to the previous
     date's day. DST is handled implicitly: we only ever use the offset captured at log
     time.)
  3. If that date's day was already **closed** (a `DayClosed` event for date D with
     `logged_at` earlier than this event's `logged_at`) → attribute to the next date
     (D+1). ("I closed my day, went to bed, then logged water at 11:30 PM" = tomorrow.)
     Explicit `effective_date` (rule 1) bypasses this — that's how you edit yesterday.
- `day_index(date)` = days since `start_date` + 1. Day 1 = start_date. Dates outside
  [1, length_days] still attribute; projections mark them `out_of_range`.
- "Yesterday stays editable until closed" is a **UI concern**: the UI offers "log for
  yesterday" (passing `effective_date`) whenever yesterday's day is not closed.

## Event schema

`events` table: `id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT UNIQUE, challenge_id
TEXT, logged_at_epoch INTEGER, tz_offset_secs INTEGER, effective_date TEXT NULL, kind
TEXT, payload TEXT (JSON), schema_version INTEGER DEFAULT 1`.

Kinds (payload fields):
- `water_add { ml: i64 }` — canonical unit is **milliliters**; UI displays fl oz
  (1 fl oz = 29.5735 ml; 1 gallon = 3785 ml).
- `water_adjust { ml: i64 }` — NEGATIVE-ONLY signed correction (-10_000..=-1) for
  over-recorded water (drag-down on Jerome). Day totals fold adds+adjusts
  chronologically with a running floor at 0; the chug window nets live corrections
  only against water logged before them. Never fires day_became_complete.
- `no_junk_ok {}` — the no-junk-or-alcohol attestation, a SIXTH core task (mirrors
  my sister's sheet's separate column). Events carry `schema_version` (v2 = six-task era);
  days lived before a store's first v2 event inherit diet for no_junk (legacy
  grandfathering), as do backfill payloads missing the flag.
- `workout { duration_min: u32, outdoor: bool, note: Option<String>,
  started_at: Option<LocalInstant> }`
- `reading { book_title: String, pages: u32 }`
- `diet_ok {}`
- `photo_done { photo_ref: Option<String> }` — photo files stay on device in the app's
  private container; the core stores only a ref string. Never surfaced in share cards.
- `extra_done { extra_id: String }`
- `day_closed { date: String }` — closes the given date's day (usually "today").
- `day_backfilled { date, water, outdoor_workout, second_workout, reading, diet, photo,
  extra_ids: Vec<String> }` — one per backfilled day; flags mark tasks complete.
- `goal_changed { water_goal_ml: i64 }` — goal is evaluated **as of each day** so past
  days keep the goal they were lived under.
- `revoked { event_uuid: String }`

Other tables (not append-only; plain config):
`challenge` (id, created_at, ruleset, start_date, length_days, day_cutoff_minutes,
waking_start_minutes, waking_end_minutes, initial_water_goal_ml, diet_description,
current_book, active), `container_presets` (id, challenge_id, name, ml, sort_order),
`extra_defs` (id, challenge_id, name, cadence 'daily'|'weekly', enabled). Phase 1 ships
exactly one optional extra preset: id `job_application`, "Apply to a job", weekly.

## Flexible-mode day completion (mirrors my sister's sheet)

A day's **core tasks** (all six must be done for `core_complete`):
1. **Water**: folded sum of ml (adds + corrections, floored) ≥ goal-as-of-that-day.
2. **Workout (outdoor)**: ≥1 workout with `outdoor = true` (any duration in flexible).
3. **Workout (second)**: total workouts ≥ 2.
4. **Reading**: pages sum ≥ 10.
5. **Diet**: ≥1 `diet_ok`.
6. **No junk or alcohol**: ≥1 `no_junk_ok` (see legacy grandfathering above).
7. **Photo**: ≥1 `photo_done`.
(Displayed as six tiles; the workout tile has two directly-tappable slots.) Backfilled
flags satisfy tasks directly; such days report `is_backfilled`. CSV export carries the
"No Junk or Alcohol" column right after Nutrition/Diet.

Weekly extras bind to week = 7-day blocks by day index (week 1 = days 1–7, matching
my sister's sheet), **never** gate `core_complete`, and get their own smaller weekly moment.

Missing a day never resets anything in flexible mode. Summary reports
`days_complete_count`, `current_run` (consecutive complete days ending at today-if-
complete else yesterday), `today_day_index` (clamped to [1, length_days] for display;
`today_out_of_range` carries the truth), and `today_raw_day_index` (UNCLAMPED —
out-of-range days still attribute events, so destructive-flow copy like the reset
sheet's "N days will be deleted" must use this figure, never the clamped one).

## Water pacing & safety (all modes, not configurable off)

- `WaterState { total_ml, goal_ml, remaining_ml, pace_target_ml, on_pace, final_ounce,
  discourage_catch_up }` for a given `now`:
  - `pace_target_ml` = goal × elapsed fraction of the waking window
    [waking_start, waking_end], clamped to [0, goal]. `on_pace` = total ≥ target − 250 ml.
  - `final_ounce` = 0 < remaining ≤ 150 ml (the "drink that final ounce" nudge).
  - `discourage_catch_up` = within 90 min of waking_end AND remaining > 1000 ml. UI copy
    must never cheer late-night catch-up; it shows the anti-chug message instead.
- **Anti-chug guard**: `check_chug(now, add_ml)` → warn when (ml logged in the trailing
  60 min) + add_ml > **1000 ml**. The UI warns and requires explicit confirmation; it
  never celebrates an over-limit log. This is a safety feature and ships in every mode.

## Core public API (UniFFI, proc-macro mode)

One exported object, `DromeStore` (internally `Mutex<rusqlite::Connection>`):

```
DromeStore::open(db_path: String) -> Result<Arc<DromeStore>>
active_challenge() -> Option<Challenge>
create_challenge(cfg: NewChallenge) -> Challenge        // NewChallenge includes optional past start_date + created_at: LocalInstant (core is clock-free)
update_presets(presets: Vec<ContainerPreset>) / set_extra_enabled(id, bool)
container_presets() -> Vec<ContainerPreset> / extra_defs() -> Vec<ExtraDef>
set_current_book(title) / set_water_goal(ml, now)       // goal change = event
set_diet_description(desc) / set_waking_window(start_minutes, end_minutes)  // display/pacing config; safe to edit mid-challenge
// NOTE: day_cutoff_minutes has deliberately NO setter — changing it mid-challenge would
// re-attribute past events (could flip completed days). Needs goal_changed-style
// as-of-day semantics; deferred past Phase 1. UI shows the value read-only.
import_json(snapshot: String) -> ()   // restore an export_json snapshot; only into a store with no active challenge
reset_all_data() -> ()   // wipe EVERYTHING (events/challenge/presets/extra_defs) back to never-used, ONE transaction: append-only triggers dropped and recreated identically inside it (failure = complete no-op); VACUUM after commit is best-effort. Settings "Start over" only; the app layer owns photos/flags/widget cleanup
// Every write path runs its precondition read (active challenge / target rows) and its
// INSERTs in one BEGIN IMMEDIATE transaction: the widget process shares this WAL DB on
// its own connection, so a write racing reset_all_data fails NoActiveChallenge instead
// of orphaning an event under the deleted challenge id.
log_water(ml, now, effective_date: Option<String>) -> LogResult
log_water_adjustment(ml, now, effective_date) -> LogResult  // negative-only correction; rejected when |ml| exceeds the day's total
log_no_junk_ok(now, effective_date) -> LogResult
water_log(date, now) -> Vec<WaterLogEntry>  // signed per-day pour ledger (event_uuid, ml, logged_at, retro), attribution identical to day_state
log_workout(duration_min, outdoor, note, started_at: Option<LocalInstant>, now, effective_date) -> LogResult
log_reading(book_title, pages, now, effective_date) -> LogResult
log_diet_ok(now, effective_date) -> LogResult
log_photo_done(photo_ref, now, effective_date) -> LogResult
log_extra_done(extra_id, now, effective_date) -> LogResult
close_day(date, now) -> DayState
revoke_event(event_uuid, now) -> ()
revoke_task(date, kind: RevocableTask, now) -> LogResult  // kind = Diet|NoJunk|Photo|Reading|Extra{id}: un-complete a task on the date. Attest kinds (Diet/NoJunk/Photo/Extra) are idempotent, not additive: ALL their live events attributed to the date are revoked in one transaction, so one call always flips the task to not-done (e.g. "mark photo taken" + attach = two live events). Reading is additive and peels newest-first, entry by entry. Typed TaskNotRevocable when only a backfill flag (or nothing) satisfies it. Water/workouts revoke entry-by-entry via revoke_event instead.
backfill_days(days: Vec<BackfilledDay>, now) -> ()      // single transaction
day_state(date, now) -> DayState
today(now) -> TodayState        // date, day_index, DayState, WaterState, week extras
summary(now) -> ChallengeSummary
calendar(from_date, to_date, now) -> Vec<DayBrief>      // for backfill grid + history
water_state(now) -> WaterState
check_chug(now, add_ml) -> ChugCheck
share_card(date, now) -> ShareCardData                  // day #, task states, run, workouts w/ durations+outdoor, ruleset label; NO photo refs
export_json(now) -> String                              // full: config + events + day states
export_csv(now) -> String                               // day-per-row, columns mirroring my sister's sheet
```

`LogResult { event_uuid, day_state, day_became_complete: bool, week_extra_became_complete:
bool, chug_warning: Option<ChugCheck>, revoked_photo_refs: Vec<String> }`.
`day_became_complete` fires the completion moment exactly once (core compares pre/post
state). Revokes (`revoke_task`) return both moment flags hard-false — the moments then
fire again, intentionally, on the log that re-completes the day/week (a genuine flip).
`revoked_photo_refs` is filled only by `revoke_task(_, Photo, _)`: every revoked
event's photo ref, so the app layer can delete the orphaned image files.
`WeekExtraState.done_on_date` reports the date whose completion satisfies each extra
(live-event dates preferred over backfill-flag dates), so a toggle-off UI can target
`revoke_task` at the right day.
`DayState.revocable { diet, no_junk, photo, reading, extra_ids }` reports per task
whether `revoke_task` would succeed on that date: true only when a live (non-revoked)
event of the kind is attributed there — tasks satisfied only by `day_backfilled` flags
read false. Errors: `DromeError` enum → Swift `throws`. All API types are UniFFI
Records/Enums; dates are "YYYY-MM-DD" strings; core validates and never panics across
the FFI boundary.

## Swift layer contracts

- **`DromeShared/Models.swift`** — Swift-native mirrors of the core records (structs,
  `Sendable`, `Identifiable` where sensible). Views use ONLY these types.
- **`DromeShared/DromeCoreClient.swift`** — protocol mirroring the core API (throwing
  funcs, Swift models). Captures `LocalInstant.now` internally (each impl stamps time; views never pass time).
- **`DromeShared/MockDromeCore.swift`** — in-memory impl seeded with the demo fixture:
  start 2026-06-21, days 1–12 complete, day 13 missing reading, day 14 (today) partial,
  job_application extra enabled, 24 oz bottle preset. Used by previews and the view
  fan-out build stage.
- **`DromeShared/LiveDromeCore.swift`** — maps UniFFI generated types ↔ Models. Only this
  file and Generated/ may import the bindings.
- **`Drome/AppModel.swift`** — `@MainActor @Observable final class AppModel`: owns a
  `DromeCoreClient`, caches `TodayState`/`ChallengeSummary`, exposes intent methods
  (logWater, logWorkout, …) that call the client, refresh state, and set
  `pendingCompletionMoment` / `pendingChugWarning` for the UI. Injected via
  `.environment(appModel)`.
- **`Drome/DesignSystem.swift`** — tokens only here; no hex literals in feature views:
  - Colors (light/dark pairs, defined in code, not assets): `dromeSand` bg
    #F3EAD8/#1C1917, `dromeInk` text #292524/#EDE3D1, `dromeClay` accent #C2410C,
    `dromeCamel` #B45309, `dromeOasis` water #0E7490/#22D3EE, `dromeDone` #15803D,
    `dromeMiss` #B91C1C (used sparingly, honest-not-shaming).
  - Type: system font; headers `.black` weight with tight tracking ("gear, not toy");
    counters use monospaced digits. Generous tap targets (44pt+); one-hand reach.
  - `CamelView(fill: Double, celebrating: Bool)` lives in `Drome/Views/CamelView.swift`
    behind a stable API. Its visible outline is Melissa's refined Jerome vector trace;
    the animated SwiftUI water layers use the matching accepted alpha silhouette.
- **Widget** (`DromeWidget/`): WidgetKit + AppIntents. `LogWaterIntent(presetId)` opens
  the store at the shared path, logs, reloads timelines. Widget shows camel fill +
  preset buttons (interactive, iOS 17). App and widget communicate only through the
  shared SQLite file; after any app-side log, call `WidgetCenter.reloadAllTimelines()`.

## File ownership map (build-stage parallelism)

Shell stage: pbxproj, DromeApp.swift, AppModel.swift, RootView.swift, DesignSystem.swift,
Models.swift, DromeCoreClient.swift, MockDromeCore.swift, Assets, entitlements.
Bindings stage: build-xcframework.sh output, Generated/, LiveDromeCore.swift, pbxproj
framework linkage. Feature stages (one agent each, files exclusive): DayBoardView;
WaterView+CamelView; WorkoutView; ReadingView+DietView+PhotoView; CompletionMomentView;
ShareCardView; BackfillView+OnboardingView; SettingsView+ExportBackupView; DromeWidget/*.
Feature views never edit shared files; integration stage wires RootView.

## Build & verify commands

- Core: `cd core && cargo test` (plain cargo, default target dir — the Santa profile
  allowlists this repo's `core/target/`; see CLAUDE.md). Also `cargo fmt --check`,
  `cargo clippy --all-targets -- -D warnings`. CI runs the same on Linux.
- Sim static lib + bindings: `core/build-ios-lib.sh` (aarch64-apple-ios-sim staticlib +
  uniffi-bindgen swift output → `ios/DromeShared/Generated/`), invoked standalone or by
  the app target's run-script phase. Device (`aarch64-apple-ios`) static libs build the
  same way (never executed on host); TestFlight at week 4 needs only App Store Connect
  access.
- App: `xcodebuild -project ios/Drome.xcodeproj -scheme Drome -destination
  'platform=iOS Simulator,name=Chart35iPhone' build` — Chart35iPhone (iOS 26.5) is the
  only simulator on this machine. (Agents: use a private `-derivedDataPath` under the
  session scratchpad to allow parallel builds.)

## Binding guardrails (from the research; enforced at review)

No calorie/macro tracking. No streak freezes or partial-credit celebration (confetti only
for a fully complete day). No social surfaces, feeds, likes. No analytics, no network
calls (the only data leaving the device: user-initiated export/backup and the share-card
image the user sends). Flexible is default; purist is opt-in and has no Phase 1 UI.
Anti-chug guard in all modes. Photos on-device only and never in share cards. Honest
labels: backfilled days are marked; share cards carry the ruleset label.
