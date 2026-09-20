# Adversarial Review: Android Phase 4 Plan

**Reviewed:** `docs/ANDROID.md`  
**Date:** 2026-07-20  
**Verdict:** Directionally strong, but not ready to become binding.

The central strategy is sound: a native Kotlin/Jetpack Compose client, shared Rust
logic through UniFFI, local-first operation, and feature parity before Android-only
expansion. However, the plan currently contains seven implementation blockers and
three material contract gaps. Several are not speculative risks: the Wear application
ID conflicts with a hard Data Layer requirement, the auth migration contradicts the
server that exists today, and the widget design assumes a process model Android does
not provide.

Priority labels in this review mean:

- **P1:** Must be resolved before the document becomes binding or before the affected
  milestone starts. The current plan would otherwise fail, lose or misattribute data,
  or be rejected at release.
- **P2:** Must be resolved during architecture work before the affected feature is
  implemented. The direction is usable, but the current contract is incomplete,
  obsolete, or not testable.

## Findings

### 1. [P1] The Wear application ID prevents Data Layer communication

`docs/ANDROID.md` assigns `day.drome.app` to the phone app and
`day.drome.app.wear` to the Wear app, then specifies communication through the
Wearable Data Layer.

Google Play services requires the phone and watch applications using the Data Layer
to have matching package names and matching signatures. M7 therefore cannot work as
specified. Keeping the IDs merely similar is not sufficient.

Required correction:

- Use the same installed application ID for the phone and Wear artifacts.
- Keep separate Gradle modules, manifests, form-factor declarations, and release
  artifacts as needed, but use the same signing lineage.
- Add a Data Layer connection smoke test to M7 acceptance.

Source: [Android Data Layer overview](https://developer.android.com/training/wearables/data/overview)

### 2. [P1] The proposed identity migration would misclassify existing accounts

The plan says Phase 2 authentication is Apple-only, describes email authentication as
future magic-link work, and proposes migrating every existing `account.apple_sub`
value to an identity row with `provider='apple'`.

That premise is already stale. The current server implements email OTP through
`POST /v1/auth/email/request` and `POST /v1/auth/email/verify`; iOS already consumes
those endpoints. Email accounts are stored in the existing `apple_sub` column as
`email:<normalized-address>`, while development accounts use `dev:<key>`.

Migrating every row as Apple would misclassify email and development identities,
potentially strand accounts, and allow duplicate replacement accounts to be created.

Required correction:

- Describe the shipped email mechanism as email OTP, not a magic link.
- Inventory all values currently stored in `account.apple_sub`.
- Define a provider-aware migration for Apple, email, and development identities.
- Add pre-migration validation, post-migration uniqueness checks, rollback behavior,
  and tests over a database containing every current identity kind.
- Define a compatibility window if old server or client builds can overlap the new
  schema during deployment.

Evidence:

- [`server/src/auth.rs`](../server/src/auth.rs), email request and verification handlers
- [`server/src/db.rs`](../server/src/db.rs), current `account.apple_sub` schema
- [`ios/Drome/AppModel.swift`](../ios/Drome/AppModel.swift), existing email OTP client flow

### 3. [P1] Account linking defers the actual data-integrity problem

The proposed link-code endpoint authenticates intent, but the plan does not say what
happens when the Apple identity and email identity already belong to two populated
accounts. A production link operation may need to reconcile:

- event streams and server sequence allocation;
- config slots and the one-active-challenge invariant;
- group memberships, duplicate membership, handles, and nudges;
- entitlements and RevenueCat ownership;
- sessions and refresh-token rotation;
- account deletion and retention of the losing account ID;
- client-side local-data ownership and sync cursors keyed by numeric account ID.

The existing iOS client deliberately binds local data and sync context to the server's
numeric account ID. A server-side merge that changes the canonical ID can therefore
cause the client to reject its own account or begin syncing under a fresh cursor unless
the response and migration protocol explicitly repair that state.

Required correction:

- Prefer attaching a newly verified identity to an existing authenticated account
  before a second account is created, if product UX permits it.
- If populated-account merging is supported, specify an atomic and deterministic merge
  algorithm for every dependent table and client-side context.
- Make link codes short-lived, one-time, hashed at rest, rate-limited, and protected by
  recent authentication.
- Add cross-platform tests where both accounts already have challenges, events, groups,
  sessions, and entitlements.
- Make account linking an explicit M4 acceptance criterion rather than an open question.

Evidence: [`ios/Drome/AppModel.swift`](../ios/Drome/AppModel.swift) stores the local
owner account ID and uses that ID as the core sync context.

### 4. [P1] The Glance design relies on an invalid single-process assumption

The plan says the Glance widget runs in the app process and logs through the same
`LiveDromeCore`. Android's widget documentation explicitly treats widgets as hosted in
a different process and warns that in-memory application state can disappear at any
time.

The design therefore cannot rely on a shared `DromeStore`, `StateFlow`, ViewModel, or
other process-local singleton to keep the widget and foreground board coherent.

Required correction:

- Treat widget rendering and actions as stateless process entry points.
- Define lazy, per-process store initialization and WAL-safe concurrent connections.
- Confirm that every widget mutation is a single core transaction and stays within
  receiver execution limits; delegate longer work appropriately.
- Define how a widget write invalidates or refreshes a foreground activity running in
  another process.
- Test app and widget concurrency, app process death, widget-host process death, and
  rapid repeated taps.

Sources:

- [Manage and update GlanceAppWidget](https://developer.android.com/develop/ui/compose/glance/glance-app-widget)
- [Create an app widget with Glance](https://developer.android.com/develop/ui/compose/glance/create-app-widget)

### 5. [P1] The backup exclusion contract is incomplete and easy to implement incorrectly

The plan says `dataExtractionRules` will exclude the database and session preferences,
but this does not cover the full supported OS range. `dataExtractionRules` applies to
Android 12 and later; an app with `minSdk 26` must also supply legacy
`fullBackupContent` rules for Android 11 and earlier.

The database is also placed at `filesDir/drome.sqlite`. In Android backup rules that is
the `file` domain, not the `database` domain. An implementer following the prose and
excluding only a database-domain path would leave the actual file eligible for backup.
The SQLite WAL and shared-memory sidecars also require a consistent policy; restoring
only part of the set can produce stale or incomplete state.

Required correction:

- Specify both modern `dataExtractionRules` and legacy `fullBackupContent` resources.
- Exclude the correct `file`-domain paths for `drome.sqlite`, its WAL, and its SHM file,
  or store the database through the platform database path and document that instead.
- Exclude device-specific sync state and token material in both cloud-backup and
  device-transfer modes as intended.
- Name the actual M2 off-device backup mechanism. A reasonable parity path is a
  user-initiated Storage Access Framework document saved to Drive or another provider,
  with the same visible stale-backup state as iOS.
- Test backup extraction on API 26–30 and API 31+, plus uninstall/reinstall restoration
  before account sync exists.

Source: [Android Auto Backup rules](https://developer.android.com/identity/data/autobackup)

### 6. [P1] Wear quick-add has no durable delivery protocol

The Wear section names Message and Data clients but does not define delivery semantics.
`MessageClient` is best-effort, has no persistence or built-in retry, and requires the
nodes to be connected. `DataClient` persists while offline, but a naïve design that
updates one path can overwrite repeated water taps before the phone consumes them.

For a product whose primary data rule is that progress cannot be lost, a fire-and-forget
watch button is not acceptable.

Required correction:

- Persist a small Kotlin-side outbox on the watch; no watch-side Rust is required.
- Give every mutation a UUID and immutable payload.
- Send each pending command through a unique persistent DataItem or another explicitly
  durable protocol.
- Make phone ingestion idempotent and return an acknowledgement.
- Delete watch commands only after acknowledgement.
- Show pending, delivered, and failed state on the tile/app.
- Test disconnected phone, reconnect, duplicate delivery, phone replacement, rapid
  repeated taps, and watch process death.

Source: [Choose a Wear Data Layer client](https://developer.android.com/training/wearables/data/client-types)

### 7. [P1] NDK r28 does not prove that the finished app is 16 KB compatible

NDK r28 makes newly compiled Drome/SQLite native libraries 16 KB aligned by default.
It does not retrofit prebuilt native dependencies. The proposed JNA AAR contributes its
own `libjnidispatch.so`, which must independently be compatible. Other SDKs introduced
later can do the same.

The current plan treats the selected NDK as proof of compliance and provides no
finished-package verification gate. That can produce an AAB rejected by Play or a
runtime crash on a 16 KB device despite `libdrome_core.so` itself being correct.

Required correction:

- Pin AGP 8.5.1 or later and a JNA version verified for all shipped ABIs.
- Inspect every packaged `.so`, not just Drome's output.
- Run ELF-segment alignment checks, `bundletool` alignment inspection, and
  `zipalign -c -P 16` on release artifacts in CI.
- Add a runtime smoke test on a 16 KB page-size emulator or device.

Sources:

- [Support 16 KB page sizes](https://developer.android.com/guide/practices/page-sizes)
- [`zipalign` verification](https://developer.android.com/tools/zipalign)

### 8. [P2] The cross-platform export acceptance test cannot pass as written

M2 requires an iOS export to restore on Android and then re-export byte-equivalently,
modulo formatting. The current export format contains a fresh `exported_at` value and
time-dependent `days` and `summary` projections. Re-exporting at a later instant is
therefore semantically different, not merely formatted differently.

Attached photos create a second ambiguity. Export JSON carries the local photo reference
but not the image bytes. The reference is meaningful only if the corresponding file is
transferred into the destination platform's private photo store. The Android plan calls
the restore clean without defining whether the task remains checked, the attachment is
dropped, or photos are moved in a companion archive.

Required correction:

- Compare a canonicalized importable subset: challenge, presets, extras, and events.
- Compare projected states separately at a fixed injected `LocalInstant`.
- Ignore or independently assert generated export metadata.
- Decide and test the cross-platform photo policy: check-off-only restoration with a
  null attachment, or an explicit archive containing photos and a reference remap.
- Add fixtures with revoked events, attached photos, config changes, and sync-origin
  events rather than testing only the demo happy path.

Evidence: [`core/src/export.rs`](../core/src/export.rs) includes `exported_at`, projected
days, and summary in every JSON export.

### 9. [P2] The token-storage contract mandates an already deprecated API

The plan prescribes `EncryptedSharedPreferences`. AndroidX has deprecated
`EncryptedSharedPreferences` and the full stable `security-crypto` API, and states that
there will be no subsequent releases. A plan authored ahead of Phase 4 should not bind
the implementation to an abandoned storage abstraction.

Required correction:

- Choose a supported storage design backed by Android Keystore according to the threat
  model at Phase 4 start.
- Specify atomic replacement of access and rotating refresh tokens.
- Serialize concurrent refresh attempts from sync, groups, entitlement checks, and
  account deletion.
- Define recovery from a missing/invalidated Keystore key as a safe local sign-out,
  never destructive local-data reset.
- Exclude token ciphertext and any device-bound key metadata from backup.

Sources:

- [Android cryptography guidance](https://developer.android.com/privacy-and-security/cryptography)
- [`EncryptedSharedPreferences` API](https://developer.android.com/reference/androidx/security/crypto/EncryptedSharedPreferences)

### 10. [P2] “WorkManager/AlarmManager” is not a reminder contract

WorkManager and AlarmManager are not interchangeable implementation details.
WorkManager periodic work has coarse timing. Inexact alarms may be delayed, especially
under Doze. Exact alarms require special access on modern Android, and the automatically
granted `USE_EXACT_ALARM` permission is Play-restricted to narrow alarm, timer, and
calendar use cases.

The feature promises deficit-driven and deadline-aware reminders, so the acceptable
precision and degradation behavior are part of the product contract.

Required correction:

- Decide the required precision for ordinary reminders and purist feasibility warnings.
- Prefer inexact alarms where possible and document whether Drome will request the
  user-granted `SCHEDULE_EXACT_ALARM` access for any genuinely precise feature.
- Do not assume eligibility for `USE_EXACT_ALARM` without a Play policy determination.
- Define behavior when permission is absent or revoked.
- Recompute and reschedule after device reboot, app update, wall-clock or timezone
  change, cutoff/waking-window edit, task completion, and challenge reset.
- Test Doze, battery saver, force-stop expectations, and DST/travel transitions.

Sources:

- [Schedule alarms](https://developer.android.com/develop/background-work/services/alarms)
- [Google Play exact-alarm policy](https://support.google.com/googleplay/android-developer/answer/16558241)

## Additional weaknesses to resolve during M1 planning

These are not independent blockers, but the document should tighten them while the P1
items are being corrected:

- Freeze a concrete Phase 4 parity matrix at kickoff rather than allowing “whatever iOS
  has then” to remain the working scope throughout implementation.
- Test every handwritten Generated-to-Kotlin model mapping. A real-library smoke test
  covering only open/log/project/export does not exercise sync records, optional fields,
  every enum/error, config conflicts, or numeric conversions.
- Serialize AppViewModel mutations through one actor/queue or otherwise prevent two
  rapid suspend operations from publishing results out of order and regressing UI state.
- Define App Links and the hosted `assetlinks.json` contract for group-invite URLs;
  sharing an iOS-style identifier does not configure Android App Links.
- Pin `targetSdk 36` for a release after August 31, 2026 rather than describing API 36 as
  merely expected. Wear OS has a separate API 35 requirement for that deadline.
- Expand the Play Data Safety inventory to include optional synced fitness/challenge
  data, login email, group identity, purchases handled by RevenueCat, and any diagnostic
  data collected by dependencies. “No data collected by default” is not a sufficient
  submission inventory.

## Recommended disposition

Do not mark `docs/ANDROID.md` binding in its current form.

Before Phase 4 kickoff:

1. Resolve all P1 findings in the plan itself.
2. Add an identity/linking sub-contract and a durable Wear command protocol.
3. Replace the one-process widget model with an explicitly process-safe design.
4. Turn backup and 16 KB compatibility into testable release gates.
5. Resolve the P2 decisions no later than the milestone that first depends on them.

Once those changes are made, the overall architecture is a strong basis for an Android
implementation. The shared core eliminates much of the domain-risk, but it does not
eliminate Android's identity, process, background-execution, backup, native-packaging,
or wearable-delivery constraints. Those are the areas the binding plan must pin down.

---

# Adjudication (2026-07-20)

Each finding was verified against the codebase where it cited evidence, and against
platform requirements otherwise. **Result: 9 of 10 findings sustained (two with
modification), one partially overruled. All six "additional weaknesses" accepted.**
`docs/ANDROID.md` has been revised in the same pass; it remains a plan that becomes
binding at Phase 4 kickoff, per its own header.

## Rulings

1. **Wear application ID — SUSTAINED.** The Data Layer does require matching package
   names and signatures. Plan corrected: `day.drome.app` for both artifacts, separate
   `:app`/`:wear` modules, one signing lineage, Data Layer smoke test added to M7
   acceptance.

2. **Stale auth premise — SUSTAINED (verified).** `server/src/auth.rs` confirms
   `POST /v1/auth/email/request` / `verify` (six-digit OTP, resend cooldown, hashed
   code) and the `email:<addr>` / `dev:<key>` identity convention in
   `account.apple_sub`; `AppModel.swift` confirms the iOS client flow
   (`requestEmailCode` / `verifyEmailCode`). The plan's auth section was rewritten:
   Android launches on the existing email OTP with zero new server auth work; the
   identity refactor is now conditional on adding Google Sign-In and specifies a
   provider-aware migration (prefix parsing, inventory, uniqueness checks, rollback,
   three-identity fixture tests). Note the upside the review understated: this
   finding *shrinks* M4's server dependency rather than adding work.

3. **Account linking — SUSTAINED WITH MODIFICATION.** Verified: `AppModel.swift`
   binds the local-data owner and the core sync context to the numeric account id
   (lines ~143–224, ~505–510), so a canonical-ID-changing merge is genuinely
   hazardous. Adopted the review's own preferred branch: **attach-first** (link an
   identity to the existing account before a second account can be created; codes
   single-use, short-TTL, hashed, rate-limited) and **populated-account merge ruled
   explicitly out of scope** rather than specifying a merge algorithm. Linking is
   now an M4 acceptance criterion. The demand for a full merge protocol is not
   adopted — that is a dedicated future design if ever wanted.

4. **Glance single-process claim — OVERRULED IN PART, SUSTAINED IN PART.** The
   headline is incorrect: `GlanceAppWidget` composition and `ActionCallback` code
   execute in the app's own process; the documentation's "hosted in a different
   process" refers to the launcher rendering the widget UI. One process / one DB /
   one `DromeStore` stands, and no multi-process WAL design is needed (that would
   re-import an iOS constraint Android doesn't have). Sustained and folded in: the
   process may be *cold-started by a widget tap*, so entry points are stateless,
   the store lazy-initializes, no live Activity/ViewModel is ever assumed,
   mutations stay within receiver limits, foreground refresh on ON_RESUME, and the
   concurrency/process-death test list.

5. **Backup rules — SUSTAINED.** `dataExtractionRules` is API 31+ only;
   `fullBackupContent` added for API 26–30. `filesDir` paths are `file`-domain;
   the WAL/SHM sidecars are excluded as a set; the M2 off-device mechanism is named
   (SAF document export with visible "last backed up" state); API-range and
   reinstall tests added.

6. **Wear durability — SUSTAINED.** Adopted wholesale: persisted watch-side outbox,
   per-command UUID DataItems, idempotent phone ingestion (riding the core's
   existing uuid dedup), ack-then-delete, honest pending/delivered UI, and the full
   failure-mode test list.

7. **16 KB compliance — SUSTAINED.** Reframed in the plan as a package property:
   AGP ≥ 8.5.1 + verified JNA pin, per-`.so` ELF alignment sweep, `zipalign -c -P
   16` / bundletool inspection, and a 16 KB-emulator boot smoke — all as CI release
   gates.

8. **Export acceptance test — SUSTAINED (verified).** `core/src/export.rs` includes
   `exported_at` + projected `days`/`summary` in every export, and `Snapshot`
   deliberately imports only the config+events subset. Byte-equivalence could never
   pass. M2 acceptance rewritten: canonicalized importable subset compared;
   projections compared at a fixed injected `LocalInstant`; generated metadata
   asserted independently; photo policy decided (check-off restores, missing
   attachments degrade gracefully); fixtures extended beyond the happy path.

9. **Deprecated token storage — SUSTAINED.** The `EncryptedSharedPreferences`
   prescription is removed; replaced with a Keystore-backed mechanism chosen at
   phase start plus a mechanism-independent contract (atomic pair replacement,
   serialized refresh, safe sign-out on key loss — never data reset, backup
   exclusion).

10. **Reminder contract — SUSTAINED.** Reminders are now specified inexact-by-design
    (WorkManager/inexact alarms, Doze-tolerant copy); no assumed `USE_EXACT_ALARM`
    eligibility; user-granted `SCHEDULE_EXACT_ALARM` only for a genuinely precise
    future feature, with graceful degradation; full reschedule-trigger matrix and
    Doze/DST testing.

**Additional weaknesses — all six accepted:** parity matrix frozen at M1; exhaustive
mapping-layer tests (the review is right that an open/log/project/export smoke does
not exercise the handwritten mappings); AppViewModel mutation serialization; App
Links / `assetlinks.json` planned for invite links; targetSdk pinned at kickoff
against then-current Play policy (incl. the separate Wear requirement); Play Data
Safety inventoried from the real surface, not the slogan.

## Disposition

The review's recommended disposition is accepted: `docs/ANDROID.md` was not binding
and is not being marked binding now — it is a plan, corrected per the sustained
findings, that becomes binding at Phase 4 kickoff under its own header rule. The one
correction to the review itself: Finding 4's process-model premise should not be
carried forward into implementation, or Android would inherit a multi-process
design constraint it doesn't have.
