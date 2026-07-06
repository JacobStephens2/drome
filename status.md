# Drome — Project Status

_Last updated: 2026-07-06 · repo `github.com/JacobStephens2/drome` (private) · HEAD `6b2bdbf` (30 commits)_

Drome is a free, local-first iOS tracker for 75-day challenges, built for my sister and her
group. The app, domain (`drome.day`), and mascot are all "Drome"; the camel is named
**Jerome**. Not affiliated with 75 HARD® / 44Seven Media.

**One-line status:** Phase 1 (local app) is done and prepped for TestFlight build 3;
Phase 2 (server, sync, groups, deploy) is code-complete and merged with CI green; the
server is not yet live — we're mid-way through the one-time infra bootstrap.

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
off in Release** (`FeatureFlags.serverFeatures`) so testers don't hit a Sign-in button
that dead-ends against the not-yet-deployed server.

**⏳ Owner action:** archive in Xcode (Any iOS Device → Product → Archive → Distribute →
App Store Connect), fill TestFlight "What to Test", assign to the external group, submit
for Beta App Review. Rebuild release core libs first (`core/build-ios-lib.sh --release`).

---

## Phase 2 — server, accounts, sync, groups · ✅ CODE-COMPLETE, merged, CI green (not yet live)

Contracts pinned in `docs/PHASE2.md`. Every feature adversarially reviewed; sync/groups/
reset verified live against a locally-run server.

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

## Deploy stack (infra/ + deploy/) · ✅ authored & CI-validated · ⏳ apply pending

Per `plan.md` "Server infrastructure (IaC)" + "GitOps". Nothing applied yet (no live infra).

- **`infra/`** — one OpenTofu module: DO droplet (cloud-init: docker+compose, mounted
  volume, deploy user), block volume, reserved IP, deny-by-default cloud firewall by tag,
  monitor alerts + `/healthz` uptime check, two R2 buckets (photos, litestream) + scoped
  tokens, the `drome.day` Cloudflare DNS zone + CAA, and **encrypted OpenTofu state in R2**.
  Every secret is a no-default variable. `tofu validate` passes (in CI, and locally now).
- **`deploy/`** — compose (server + Caddy + Litestream sidecar), Caddyfile, litestream.yml,
  push-based `deploy.sh` with the healthz gate + litestream restore-before-up guard.
- **`server/Dockerfile`** — multi-stage static musl build; CI builds & pushes to GHCR by SHA.
- **GitOps** — `infra-ci.yml` (fmt/validate/plan, apply behind `infra` env approval, weekly
  drift, pre-apply state snapshot since R2 has no versioning) and `server-deploy.yml`
  (build amd64 → GHCR by SHA, SSH deploy behind `deploy` env, rollback input). Both gated
  on repo vars `INFRA_ENABLED` / `DEPLOY_ENABLED` (off until bootstrap done).
- **Review** fixed 3 first-deploy criticals (container/host UID mismatch, docker-group
  cloud-init timing, floating sidecar tags).

### Bootstrap progress (in flight, Jacob-driven)

| Step | State |
|---|---|
| R2 state bucket `drome-tofu-state` created | ✅ |
| R2 state token → S3 Access Key ID (32) + Secret (64) | ✅ (in `~/.config/drome/infra.env`, admin, 600) |
| State encryption passphrase generated + stored | ✅ |
| SSH keys (admin + deploy) generated + in infra.env | ✅ (`~/.ssh/id_ed25519`, `~/.ssh/drome_deploy`) |
| `backend.hcl` (gitignored) | ✅ |
| **`tofu init`** | ✅ **succeeds** — state backend proven end to end |
| `TF_VAR_do_token` | ⚠️ looks truncated (36 chars; DO tokens ≈ 71) — re-copy |
| `TF_VAR_cloudflare_token` | ⚠️ verify (51 chars; needs Zone/DNS/R2/API-Tokens edit scopes) |
| `tofu plan` → review together → `tofu apply` | ⏳ not yet |
| Flip Porkbun nameservers → Cloudflare (≤28d of zone creation) | ⏳ |
| GitHub `infra` + `deploy` env secrets; flip enable vars | ⏳ |
| First deploy (`server-deploy` dispatch, `deploy_mode=fresh`) | ⏳ |

---

## Environment / machine notes

- **Santa Lockdown** (this Mac): host cargo works from the repo's `core/target`; the
  workspace routes `server/` artifacts there too. `tofu` 1.12.3 + the DO/Cloudflare
  provider plugins are SHA-allowlisted, so the full OpenTofu loop runs locally.
- **Do infra work as `admin`** — `infra.env`, the SSH keys, and the tofu allowlist all
  live under the admin account; switching to `eta` moves `~` and breaks paths.
- `drome.day` registered at Porkbun, currently parked at the stephens.page droplet;
  Cloudflare takes over the nameservers at apply time.
- No local Docker (Apple Silicon vs amd64 target) — CI builds the production image.

---

## Open items for Jacob (nothing blocking further dev)

1. **TestFlight build 3** — archive + upload + Test Info + Beta App Review.
2. **Finish the deploy bootstrap** — fix the DO token, verify the CF token, then
   `tofu plan` (review together) → `apply` → nameserver flip → deploy secrets → first deploy.
3. **Apple account-deletion** — a Services ID + `.p8` key so the server can revoke Apple
   tokens on account delete (App Store requirement; the local delete already works).
4. **Jerome final art + app icon** (placeholder in place).
5. **Counsel / TESS pass on "Drome"** before public launch (not needed for TestFlight).

---

## Where things live

`core/` Rust rules engine · `server/` Axum service · `ios/` SwiftUI app + widget ·
`infra/` OpenTofu · `deploy/` compose/Caddy/Litestream · `docs/ARCHITECTURE.md` (Phase 1
contracts) · `docs/PHASE2.md` (Phase 2 contracts) · planning docs in the parent folder
(`plan.md`, `decisions.md`, `phase-1-build-brief.md`).
