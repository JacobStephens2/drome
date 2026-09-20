# Android Phase 4 parity matrix

Frozen 2026-07-20 from the shipped iOS surface. “Shared core” means Android delegates rules, day attribution, projections, completion, and sync merge behavior to `drome-core` rather than reproducing them in Kotlin.

| Surface | Android owner | Status / acceptance |
|---|---|---|
| Flexible-default + purist onboarding | Compose + shared core | Implemented; purist is an explicit opt-in |
| Six-task day board + two workouts | Compose + shared core | Implemented |
| Water presets, pace, anti-chug, correction ledger | Compose/Glance + shared core | Implemented; warning is not bypassed by widget/app paths |
| Reading, diet, no-junk, on-device photo | Compose + shared core | Implemented; photo refs never sync/share |
| Universal attestations toggle/revoke | Compose + shared core | Implemented for revocable tasks; water/workouts remain entry-ledger operations |
| Completion moment | StateFlow event + Compose | Implemented without partial-credit celebration |
| Backfill + honest labels | Compose + shared core | Implemented |
| History + summary | Compose + shared core | Implemented |
| Export/restore + off-device backup | SAF + shared core | Implemented; OS backup excludes DB/WAL/sync/tokens |
| Share card | Android bitmap renderer + shared DTO | Implemented; no photo or workout note in DTO |
| Widget | Glance + shared core | Implemented; cold-start-safe quick add |
| Email OTP account | OkHttp + Keystore | Implemented; local app remains fully usable signed out |
| Sync + reset epoch | Kotlin coordinator + shared core | Implemented; token refresh serialized |
| Groups | Compose + existing server routes | Create/join/detail/member progress/nudge/pending-nudge/leave implemented; privacy-safe server DTO |
| Attach-first account linking | Compose + new server route | Implemented with five-minute single-use hashed codes |
| Inexact deficit reminders | WorkManager | Implemented; no exact-alarm permission |
| Health Connect | Read-only importer | Implemented with manual outdoor override contract |
| Wear app + tile | Compose for Wear + Tiles | Implemented, companion-only |
| Wear durable delivery | Data Layer + Rust UUID dedup | Persist-before-send outbox, per-command DataItems, phone ack, idempotent core insert |

Remaining distribution work is owner/external state rather than repository code: Play organization verification, upload-key secrets, closed-test enrollment, `assetlinks.json` deployment, and paired physical-device acceptance runs.
