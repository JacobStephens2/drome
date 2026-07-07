# Phase 1 Build Brief — Drome

You are the build agent for **Phase 1 of Drome**, an iOS-first, local-first tracker for the 75 Hard challenge. This brief is your entry point; it tells you what to build, where the details live, and what's peculiar about this machine. You are expected to work autonomously against this documentation and check in with Jacob at the milestones noted below.

## Read these, in this order

1. [decisions.md](decisions.md) — the short canonical decision log (name, domain, hosting, GitOps, repo privacy).
2. [plan.md](75hard/plan.md) — the full plan. **Your scope is the section "MVP — Phase 1: iOS, local-first, free"** plus the "Tech stack", "Design", and "The two modes" sections. Phase 2-4 sections are context only — do not build them.
3. [My sister and her 75 Hard app problem.md](My%20sister%20and%20her%2075%20Hard%20app%20problem.md) — the user this app is for. When a design call is ambiguous, this document is the tiebreaker.
4. [research/description-of-75-hard.md](research/description-of-75-hard.md) — the program's actual rules (purist mode must encode these exactly).
5. [research/what-would-make-a-hard75-app-useful.md](research/what-would-make-a-hard75-app-useful.md) — feature research; especially "What the app should refuse to do" (anti-features) — these are binding.

## What Phase 1 is

The eleven MVP items in plan.md, built in the plan's "Sequencing" order (weeks 1–2, then 3–4). In one line: a free, local-first iOS app — five-task day board, camel water tracker (any-amount + container presets + pace line + anti-chug guard), water quick-add widget, manual workout log, reading ledger, diet attestation, photo check-off, the weekly job-application preset, share-card image, mid-challenge backfill (start at Day N), append-only local persistence with export and off-device backup — flexible mode by default, purist mode deferred to fast-follow.

**Phase 1 has no server, no accounts, no payments, and no analytics.** If you find yourself writing network code other than the backup/export path, stop and re-read the plan.

Definition of done = the MVP success criteria in plan.md: any task loggable in under ten seconds; day state readable at a glance; backfill lets a mid-challenge user (my sister is around Day 50–60) onboard in minutes; data survives reinstall via export/backup; a TestFlight build is ready for my sister's group at the end of week 4.

## Workspace and repo

- Work in [75-hard-app/](75-hard-app/) (this folder's empty subdirectory; a starter CLAUDE.md is already there).
- Create a **private** GitHub repo (`gh` is available and authenticated on this machine). Suggested name: `drome`. **Confirm with Jacob before creating it** whether it belongs under his personal account or a Stephens Page LLC org.
- Monorepo layout per plan.md's GitOps section: `core/` (Rust), `ios/` — `server/`, `infra/`, `deploy/` are Phase 2 placeholders, keep them empty or absent.
- CI from day one: GitHub Actions running the Rust core's tests (Linux runner is fine for the core). iOS CI can wait.

## Stack (decided — don't relitigate)

- **`core/`: Rust.** Owns the rules engine (flexible + purist rulesets), waking-hours day-boundary math, append-only event log, day-state projections, streak/attempt logic. Exposed to Swift via **UniFFI**. Property-test the day-boundary math (sleep-anchored days, past-midnight rollover, DST). The event-log schema is sketched in plan.md ("Data model sketch").
- **`ios/`: native SwiftUI** app + WidgetKit widget. The Swift layer is views and OS integration; logic lives in the core. Local store is SQLite.
- Naming: the app is **Drome**, the camel mascot is **Jerome** (renamed 2026-07-05). **Never put "75 Hard" in the app name, bundle ID, or any store-facing metadata** (registered trademark of a litigious owner — see plan.md "Name and legal"). Suggested bundle ID pattern: `day.drome.app` or `page.stephens.drome` — pick one, record it in decisions.md.

## This machine (important constraints)

- **Santa runs in LOCKDOWN** (deny-by-default execution control for unsigned binaries, system-wide, all accounts). Known-working host tools: Apple `git` (`/usr/bin/git`), `docker`, `node`/`npm`/`npx`, `python3`/`pip3`, `gh`, `kubectl`, and Xcode (App Store, signed). **Homebrew is blocked — do not suggest or attempt `brew install`; containerize instead.** Docker container *internals* are not gated — anything can be installed and run inside a container.
- **Docker images are per-user.** A fresh user account starts with no images; pull/build your own.
- **Rust toolchain caveat:** rustup-installed `rustc`/`cargo` are unsigned binaries and may be blocked by Santa on the host. Plan accordingly:
  - Core development, tests, and CI all work fine **inside Docker** (Linux) — do this by default.
  - Building the core **for iOS targets** (aarch64-apple-ios, the simulator target) requires rustup + Xcode SDKs on the macOS host — cross-compiling to iOS from Linux is not possible. If host `cargo` is blocked, coordinate with the admin account to allowlist the toolchain (canonical Santa guide: `/Users/admin/santa/README.md`; the accountability partner holds the admin password). Test this early in week 1 — it's the likeliest environment blocker.
  - Do not attempt to weaken or bypass Santa or any monitoring on this machine; allowlisting a legitimate dev toolchain via the admin is the sanctioned path.
- **If you are running in a Linux user/VM:** everything in `core/` (and later `server/`) builds and tests there; the iOS app does not — Xcode is macOS-only. Split the work accordingly and flag the handoff points.
- Xcode simulator work needs no paid signing. TestFlight uploads use Apple Developer ID **LHY8W725A8** — App Store Connect access comes from Jacob at week 4, not before. No other secrets exist in Phase 1.

## Guardrails (binding)

- **Flexible mode is the default; purist mode is opt-in** — see plan.md "The two modes". Don't invert this.
- The **anti-features list** in research/what-would-make-a-hard75-app-useful.md is binding: no calorie/macro tracking, no streak freezes, no partial-credit celebration, no public/social surfaces, no analytics.
- The **anti-chug water guard** (warn >~1L logged per hour, never encourage late-night catch-up) ships in all modes from day one — it's a safety feature, not polish.
- Photos: Phase 1 is check-off only; if a photo is attached, it stays on-device and out of any share card.
- The completion moment and the camel are feel-driven — build them behind easy iteration (the plan expects playtesting with my sister's group). Placeholder camel art is fine until Jacob supplies/approves direction.

## Check in with Jacob (don't proceed unilaterally)

1. Repo owner (personal vs LLC org) before creating the repo.
2. Bundle ID choice (record it in decisions.md).
3. If Santa blocks host `cargo` — the allowlist step needs the admin.
4. Camel art direction, before investing in final assets.
5. TestFlight distribution at week 4 (needs his App Store Connect access).

Everything else in the Phase 1 scope is yours to build against this documentation.
