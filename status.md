# Drome — Project Status

_Last updated: 2026-07-07 · repo `github.com/JacobStephens2/drome` · **server LIVE at https://drome.day**_

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

## Deploy / infrastructure (infra/ + deploy/) · ✅ **LIVE on stephens.page** (moved 2026-11-26)

- **Hosting** — on 2026-11-26 drome.day moved off the `drome-prod` droplet onto the
  **stephens.page** server (68.183.62.24). The stack lives in **`/srv/drome`** there:
  `compose.yml` (drome-server on `127.0.0.1:8095` + Litestream sidecar), `litestream.yml`,
  `.env` (all app secrets, mode 600), `data/drome/` (SQLite, uid 10001), `web/` (static site).
  **Apache** (not Caddy) terminates TLS with a certbot cert, proxies `/v1/*` and `/healthz` to
  the server, and serves `web/` for everything else, so the landing page stays up even if the
  app container is down.
- **DNS** — Cloudflare zone; apex A → 68.183.62.24 (DNS-only).
- **`infra/`** — OpenTofu now manages only the Cloudflare zone + records, the two R2 buckets
  (photos + litestream) with scoped tokens, and the DO `/healthz` uptime check. The droplet,
  volume, reserved IP, VPC, firewall, tag, SSH key and DO project were removed from the code;
  the next `tofu apply` destroys whatever of them still exists. OpenTofu state encrypted in R2.
- **Deploys** — `server-deploy.yml` builds the image to GHCR (pinned by SHA), then
  `deploy/deploy.sh` SSHes to `drome-deploy@stephens.page`. That key is pinned
  (`restrict,command=`) to `/usr/local/bin/drome-deploy` (source: `deploy/drome-deploy`), which
  can only deploy a SHA or report status: pull image, fetch `deploy/web` at that commit,
  restore-before-up guard, switch `IMAGE_TAG`, wait for `/healthz`, roll back on failure.
  `compose.yml`/`litestream.yml`/`.env` on the host are edited by hand. Needs the `deploy`
  environment (`DEPLOY_HOST`, `DEPLOY_SSH_KEY`, `DEPLOY_SSH_HOST_KEY`) and
  `DEPLOY_ENABLED=true`. Pull auth is the job's own `GITHUB_TOKEN`, so the GHCR package must
  grant this repo Actions access.
- **`server/Dockerfile`** — multi-stage **Alpine musl** build (binary is *built* on `rust:alpine`
  and *run* on `alpine` so the musl versions match); CI builds & pushes to GHCR pinned by SHA.

**Live:** `https://drome.day/healthz` → `ok` · `https://drome.day/` + `/privacy` → marketing
site · Litestream replicating SQLite → R2 · certbot holds a Let's Encrypt cert.

**Deploy bugs found + fixed during the 2026-07-07 bootstrap:**
- cloud-init template had Unicode em-dashes → the YAML parser rejected the whole user-data,
  so the first droplet booted bare (no docker/deploy-user/volume). Fixed to ASCII `--`.
- server image built musl on Debian's `musl-tools` but ran on a glibc runtime (missing loader),
  then on Alpine (musl **version** mismatch → SIGSEGV at startup). Final fix: build in
  `rust:alpine` so build-musl == runtime-musl.
- DigitalOcean auto-deletes a droplet's monitor alerts when it's destroyed, so a cloud-init
  recreate (ForceNew) needed a second `tofu apply` to recreate the cpu/mem/disk alerts
  (moot since the droplet's removal).

---

## Environment / machine notes

Work now happens from the **`eta`** account (not `admin`).

- The project moved out of the Syncthing/Obsidian vault to **`~/repositories/drome/`**. The
  repo is the eta-owned clone at **`~/repositories/drome/75-hard-app`** (commits as
  `Jacob Stephens <jacob@stephens.page>`). Planning docs are now in-repo under `planning/`.
- **OpenTofu** runs from **`~/repositories/drome-infra`** (holds the R2-backed `.terraform` +
  gitignored `backend.hcl`); credentials in **`~/.config/drome/infra.env`** (eta, mode 600,
  outside the vault). `tofu` 1.12.3 + the DO/Cloudflare providers are Santa-SHA-allowlisted.
- `~/.ssh/drome_admin` / `~/.ssh/drome_deploy` were the droplet's keys (retired with it). The
  CI key for `drome-deploy@stephens.page` lives only in the GitHub `deploy` environment.
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
`infra/` OpenTofu · `deploy/` compose/Litestream + host deploy script (+ `deploy/web` marketing site) ·
`docs/ARCHITECTURE.md` + `docs/PHASE2.md` (contracts) · **`planning/`** (plan, decisions,
drome-specs, phase-1 build brief, the sister research note, and `research/`).
