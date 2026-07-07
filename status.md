# Drome — Project Status

_Last updated: 2026-07-07 · repo `github.com/JacobStephens2/drome` (private) · **server LIVE at https://drome.day**_

Drome is a free, local-first iOS tracker for 75-day challenges, built for my sister and her
group. The app, domain (`drome.day`), and mascot are all "Drome"; the camel is named
**Jerome**. Not affiliated with 75 HARD® / 44Seven Media.

**One-line status:** Phase 1 (local app) is done and prepped for TestFlight build 3;
Phase 2 (server, sync, groups) is code-complete and **deployed live** — the production
server, marketing site, and GitOps pipeline are all running at `drome.day`. Remaining
work is App Store onboarding (TestFlight, the Apple account-deletion key), not infra.

---

## Phase 1 — local iOS app · ✅ DONE (TestFlight build 3 ready to archive)

Native SwiftUI app + WidgetKit widget over a Rust core (UniFFI). Fully functional
offline; no accounts/network in Phase 1.

- **Day board** — six task tiles (water, two workout slots, reading, diet, no-junk,
  photo), day counter, "what's left" strip, completion moment.
- **Water + Jerome the camel** — drag **up** on Jerome to pour, drag **down** to correct;
  container presets (default 32 oz), pace line, hard-coded anti-chug guard (ounces copy),
  per-day pour ledger with swipe-to-remove.
- **Workouts** — two tappable slots (outdoor / second) togglable from the board *and* the
  detail view; manual duration + outdoor flag.
- **Reading / diet / no-junk / photo** — each its own data shape; photos stay on-device.
- **Universal task toggling** — any task flips complete ↔ incomplete anywhere.
- **Onboarding + mid-challenge backfill grid**, **share card**, **export/backup/restore**,
  **Settings → Reset Drome** (wipe with export-first double-confirm).
- **Water quick-add widget** (interactive, App Group shared DB).

Rules/dates/streaks/pacing all live in the Rust core (flexible + purist rulesets;
purist has no Phase 1 UI). Property-tested day-boundary math. **50+ core tests green.**

**Build 3 specifics:** version `1.0 (3)`, bundle `day.drome.app`, icon = placeholder
Jerome, `ITSAppUsesNonExemptEncryption=NO`. The Phase 2 **Account + Groups UI is gated
off in Release** (`FeatureFlags.serverFeatures`) — flip it on once the app ships against
the now-live server.

**⏳ Owner action:** archive in Xcode (Any iOS Device → Product → Archive → Distribute →
App Store Connect), fill TestFlight "What to Test", assign to the external group, submit
for Beta App Review. Rebuild release core libs first (`core/build-ios-lib.sh --release`).

---

## Phase 2 — server, accounts, sync, groups · ✅ CODE-COMPLETE + **DEPLOYED LIVE**

Contracts pinned in `docs/PHASE2.md`. Every feature adversarially reviewed; sync/groups/
reset verified live against a locally-run server, now running in production.

- **Core sync module** — sync = idempotent event exchange (dedup by uuid + per-account
  `server_seq`), config last-writer-wins, reset-epoch invariant (a mid-sync "Start over"
  aborts cleanly — a real data-loss bug the review caught and closed).
- **`drome-server`** (Rust/Axum) — Sign in with Apple (JWKS verify + nonce replay-binding),
  opaque bearer sessions (30-day TTL), `/v1/sync` push+pull+conflict, friend groups,
  `/healthz` (DB-checked), per-IP + per-token rate limits, free-beta entitlement gate.
  Env-gated `DROME_DEV_AUTH` for local e2e (unmounted in prod). **~34 server tests green.**
- **iOS account UI + SyncEngine** — Keychain sessions, opportunistic debounced sync,
  conflict adoption, honest sync-status surface. App stays fully usable signed out.
- **Friend groups** — each member's day count / run / per-task done, in-app nudges.
  **Privacy is structural:** hand-built minimal DTOs (never photos, notes, diet text,
  water amounts, or the weekly extra's name) + per-group opaque member handles (no
  cross-group correlation). Proven by grepping the wire for forbidden data. No
  leaderboard/competition framing.

**Decisions:** Sign in with Apple; free-beta entitlements (RevenueCat at end of phase,
enforced only at public launch). Phase order restructured: **Ph2 = server/sync/groups**,
Ph3 = watch/web/timelapse, Ph4 = Android.

---

## Deploy / infrastructure (infra/ + deploy/) · ✅ **LIVE** (applied + deployed 2026-07-07)

- **`infra/`** applied via OpenTofu on 2026-07-07 — DO droplet (id `582897580`, reserved IP
  **`209.38.51.117`**, nyc3, Ubuntu 24.04), 10 GB data volume, deny-by-default cloud firewall
  by tag, monitor + `/healthz` uptime alerts, two R2 buckets (photos + litestream) with scoped
  tokens, and the **`drome.day` Cloudflare zone (active)** + CAA. OpenTofu state encrypted in R2.
- **DNS** — Porkbun nameservers flipped to Cloudflare; zone active; apex A → the reserved IP.
- **`deploy/`** — compose (server + Caddy + Litestream sidecar). Caddy **path-splits**: `/v1/*`
  and `/healthz` proxy to the server, everything else serves the static marketing site
  (`deploy/web`), so the landing page stays up even if the app container is down. `deploy.sh`
  has a healthz gate + litestream restore-before-up guard.
- **`server/Dockerfile`** — multi-stage **Alpine musl** build (binary is *built* on `rust:alpine`
  and *run* on `alpine` so the musl versions match); CI builds & pushes to GHCR pinned by SHA.
- **GitOps** — `server-deploy.yml` and `infra-ci.yml` are live. `DEPLOY_ENABLED=true`, so a push
  to `main` touching `server/`, `core/`, or `deploy/` now **auto-builds and auto-deploys**
  (normal mode; a real DB exists, so the empty-DB guard is satisfied).

**Live:** `https://drome.day/healthz` → `ok` · `https://drome.day/` + `/privacy` → marketing
site · Litestream replicating SQLite → R2 · Caddy holds a Let's Encrypt cert.

**Deploy bugs found + fixed during the 2026-07-07 bootstrap:**
- cloud-init template had Unicode em-dashes → the YAML parser rejected the whole user-data,
  so the first droplet booted bare (no docker/deploy-user/volume). Fixed to ASCII `--`.
- server image built musl on Debian's `musl-tools` but ran on a glibc runtime (missing loader),
  then on Alpine (musl **version** mismatch → SIGSEGV at startup). Final fix: build in
  `rust:alpine` so build-musl == runtime-musl.
- DigitalOcean auto-deletes a droplet's monitor alerts when it's destroyed, so a cloud-init
  recreate (ForceNew) needs a second `tofu apply` to recreate the cpu/mem/disk alerts.

---

## Environment / machine notes

Work now happens from the **`eta`** account (not `admin`).

- The project moved out of the Syncthing/Obsidian vault to **`~/repositories/drome/`**. The
  repo is the eta-owned clone at **`~/repositories/drome/75-hard-app`** (commits as
  `Jacob Stephens <jacob@stephens.page>`). Planning docs are now in-repo under `planning/`.
- **OpenTofu** runs from **`~/repositories/drome-infra`** (holds the R2-backed `.terraform` +
  gitignored `backend.hcl`); credentials in **`~/.config/drome/infra.env`** (eta, mode 600,
  outside the vault). `tofu` 1.12.3 + the DO/Cloudflare providers are Santa-SHA-allowlisted.
- Fresh eta-held SSH keys: `~/.ssh/drome_admin` (break-glass root) and `~/.ssh/drome_deploy`
  (the CI deploy user; its private key lives in the GitHub `deploy` environment).
- Santa Lockdown; no local Docker (Apple Silicon vs amd64) — CI builds the production image.

---

## Open items for Jacob (nothing blocking — server is live)

1. **TestFlight build 3** — archive + upload + Test Info + Beta App Review.
2. **Apple account-deletion** — a Services ID + `.p8` key so the server can revoke Apple
   tokens on account delete (App Store requirement; the local delete already works).
3. **Jerome final art + app icon** (placeholder in place).
4. **Counsel / TESS pass on "Drome"** before public launch (not needed for TestFlight).
5. **DNSSEC** (optional) — enable in Cloudflare, enter the one DS record at Porkbun.
6. **Delete the parked stale checkout** `~/repositories/drome/75-hard-app.OLD-stale-admin-owned`
   from an admin shell (eta can't — its subdirs are admin-owned).

---

## Where things live

`core/` Rust rules engine · `server/` Axum service · `ios/` SwiftUI app + widget ·
`infra/` OpenTofu · `deploy/` compose/Caddy/Litestream (+ `deploy/web` marketing site) ·
`docs/ARCHITECTURE.md` + `docs/PHASE2.md` (contracts) · **`planning/`** (plan, decisions,
drome-specs, phase-1 build brief, the sister research note, and `research/`).
