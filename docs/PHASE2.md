# Drome — Phase 2 Architecture & Contracts (server, accounts, sync, groups)

Companion to ARCHITECTURE.md (Phase 1, still binding for core/ + ios/). Same rule: if
code and this doc disagree, bring the code back to the doc or change the doc in the same
commit. Product scope: plan.md "Phase 2" + "Server infrastructure (IaC)" + "GitOps" +
"Business setup". Decisions: Sign in with Apple; free-beta entitlements (decisions.md).

## Monorepo additions

```
server/          Rust crate `drome-server` (Axum) — accounts, sync, groups
infra/           OpenTofu root module (authored now, applied at deploy milestone)
deploy/          compose.yml, Caddyfile, litestream.yml, .env.template, deploy.sh
.github/workflows/server-ci.yml   test + amd64 image → GHCR (path-filtered)
.github/workflows/infra-ci.yml    tofu fmt/validate/plan on PR; apply behind environment approval
```

Dev process (plan.md, decided): local loop = `cargo run -p drome-server` with a SQLite
file beside it, iOS simulator pointed at `http://localhost:8080`; NO local Docker (Apple
Silicon vs amd64 target); CI is the only image builder; Litestream is a production
sidecar only; deploy dry-runs to the stephens.page droplet; the IaC droplet is the real
target. (Historical note: `tofu` was originally CI-only under Santa, then locally
allowlisted 2026-07-05; as of 2026-07-20 Jacob's Mac runs no Santa at all — tofu and
providers run locally without ceremony. CI remains the apply path.)

## Sync protocol (the heart — same event-sourcing spine as Phase 1)

Client events are immutable, globally unique by uuid, and additive; revocations and
corrections are themselves events. Therefore **sync = idempotent event exchange**; the
projections never sync, they recompute.

- Server stores per-account event rows: client event fields + `account_id` +
  `server_seq` (monotone per account, assigned on insert) + `device_id`.
- **Push**: client sends events it hasn't had acked (client tracks a local
  `synced_through` watermark over its own event table). Server upserts **dedup by
  uuid** (replays are no-ops), assigns server_seq, acks with the uuids + new seqs.
- **Pull**: client sends its `last_server_seq`; server returns newer events from
  *other* devices, **scoped to the account's one active challenge** (archived-loser
  events never propagate — see below), and the client applies them idempotently
  (skip uuids it already has) AND advances the cursor **in one core transaction**
  (`apply_pull_batch`), so a crash can never advance the cursor past events that
  were not durably applied. A device that ran a local "Start over"
  (`reset_all_data`) re-mints its device id, so on its next sync the server no
  longer treats that account's server-held events as this device's self-echoes and
  returns them — the reset device recovers its full history (uuid dedup keeps the
  re-pull idempotent, so a steady-state sync neither loops nor duplicates).
- **Reset epoch (sync/reset atomicity — a core-enforced invariant)**: a local
  "Start over" and an in-flight sync round-trip must not corrupt each other. The
  store keeps a monotonic `reset_epoch` in a single-row `sync_epoch` table that is
  the ONE piece of sync state `reset_all_data` does not wipe — it *increments* it,
  in the same transaction as the wipe. The SyncEngine reads the epoch ONCE at the
  start of a round-trip (`current_reset_epoch`) and threads it back into every
  cursor-or-state-**mutating** tail write — `ack_pushed`, `apply_remote_config`,
  `set_last_server_seq`, and `apply_pull_batch`. Each of those becomes a NO-OP,
  returning a typed `StaleReset` signal (NOT an error that breaks the flow), when
  the captured epoch no longer equals the store's current epoch. So a
  `reset_all_data` that lands between a round-trip's start and its tail invalidates
  that entire tail: a stale round-trip can never re-create `sync_state` with a
  pre-reset `last_server_seq`. Without this, a stale tail (`apply_pull_batch(ctx,
  [], N)`) would drag the pull cursor back to `N` after the reset zeroed it, so
  every later clean pull (`server_seq > N`) would skip the account's own
  re-pullable history forever — silent, permanent data loss a re-sync cannot fix.
  The happy path is unchanged (a round-trip with no interleaved reset has matching
  epochs and applies normally); a post-reset clean sync starts fresh at cursor 0
  and recovers full history. The epoch is purely client-side — the server neither
  sees nor needs it.
- Water totals, task states, runs: correct by construction — events merge additively,
  order-independent up to per-day recompute; per-event `logged_at`/`effective_date`
  travel with the event so attribution is identical on every device.
- **Config is NOT events** (challenge settings row, presets, extras): per-slot
  last-writer-wins keyed on `updated_at` (+device_id tiebreak), synced in the same
  round-trip as a `config` block. Goal changes remain events (as-of-day semantics).
- **One active challenge per account** (server-enforced): the first synced active
  challenge wins; a device pushing a *different* active challenge gets it stored
  archived (`sync_conflict` label) and the sync response carries
  `active_challenge_conflict { archived_challenge_id, winner_challenge_id }`. The
  loser MUST adopt the winner via `adopt_active_challenge(winner_config, winner_id)`,
  which force-archives its local challenge and adopts the winner **regardless of the
  config LWW stamp** — plain `apply_remote_config` cannot, because a loser whose
  challenge was created later has a newer stamp and would silently keep its own
  forever (permanent split-brain). Loser events stay owned by the archived (loser)
  challenge id: projections read only the *active* challenge's events, so they are
  never mixed into the winner's day/summary, and the server's active-challenge-scoped
  pull never propagates them to other devices. The client surfaces this honestly
  ("This phone's challenge was archived — your account already has one").
- **Photos never sync in Phase 2**: the `photo_done` event syncs WITHOUT `photo_ref`
  (stripped client-side before push; refs are meaningless off-device). Opt-in encrypted
  photo sync is a later, separate design.
- Client engine: `core/` gains a sync module (pull-new-local-events, apply-remote-events,
  config LWW merge, watermarks table) exposed via UniFFI; the iOS `SyncEngine` (Swift)
  only moves JSON over URLSession and stamps time. Sync is opportunistic (foreground +
  after logs, debounced); local-first stays the source of truth; the app is fully
  functional signed-out (accounts are opt-in, required only for sync/groups).

## Auth (Sign in with Apple)

- iOS: `SignInWithAppleButton` → identity token → `POST /v1/auth/apple`.
- Server verifies the JWT against Apple's JWKS (aud = day.drome.app, iss = apple),
  extracts stable `sub`; account row: `id, apple_sub UNIQUE, email (relay, optional),
  created_at`. **Nonce binding**: the client generates a raw nonce, sends
  `sha256(raw)` to Apple (echoed into the token's `nonce` claim) and the raw nonce
  in the `POST /v1/auth/apple` body; the server rejects the exchange unless
  `sha256(raw)` equals the claim (replay protection). Enforced whenever the token
  carries a nonce claim; legacy tokens with neither claim nor supplied nonce still
  authenticate. Issues an opaque bearer session token (random 256-bit, hashed at
  rest, rotating refresh; `Authorization: Bearer`). **Sessions live 30 days**;
  `POST /v1/auth/refresh` rotates BOTH tokens only while the session is unexpired
  (`expires_at_epoch > now`) — an expired or unknown refresh token gets the same 401,
  so the TTL is a real bound and a leaked refresh token is not a permanent
  credential. No passwords, ever.
- Deleting an account (App Store requirement): `DELETE /v1/account` wipes account rows,
  events, memberships server-side. Local data untouched.
- **Local dev auth (never production)**: real Apple identity tokens can't be minted
  headlessly, so to exercise the iOS client end-to-end against a locally-run server there
  is `POST /v1/auth/dev { account_key }`. It upserts a synthetic account
  (`apple_sub = "dev:" + account_key`) and issues the SAME opaque bearer + rotating
  refresh session as `/v1/auth/apple` (it reuses the identical `issue_session` path), so
  every downstream route treats a dev session identically; two distinct `account_key`s are
  two isolated accounts. It is gated behind env `DROME_DEV_AUTH=1`: when unset (the default,
  i.e. production) the route is **not mounted at all** — it 404s and no synthetic account is
  creatable — so it cannot be reached in a default configuration. `main` logs a loud startup
  warning whenever it is enabled. Never set `DROME_DEV_AUTH` in production.

## Groups

- `group(id, name, invite_code UNIQUE)`, `membership(account_id, group_id, joined_at)`.
- Invite = code/link (drome.day/j/<code> later; Phase 2: code entry in-app).
- Shared surface (v1): each member's display name, day index, current run, and today's
  per-task done states — derived server-side from synced events, never photos, never
  notes, never water amounts beyond done/not. **Nudges v1 are in-app** (a nudge row the
  member sees on next sync); APNs push is its own later milestone.
- Restart/reset privacy: nothing about resets/archived challenges is surfaced to groups.

## Entitlements (free beta)

- Middleware on sync/group routes checks account entitlement. Phase 2 beta: server env
  `BETA_ALL_ENTITLED=true` grants everyone; the check + client "subscription required"
  surfaces exist from day one but never fire during beta. RevenueCat webhook → entitlement
  table lands at end of Phase 2; enforced at public launch. A lapsed subscription pauses
  sync/groups only — the local app and export never degrade (plan principle 4).

## Server (drome-server)

- Axum + rusqlite (WAL) — same event-store shape as the client core; embedded migrations
  run at startup before serving (single-writer). `/healthz` (uptime check + deploy gate)
  **runs a trivial query under the db lock and returns 503 on any failure**, so it can't
  greenlight a deploy or read green over a wedged/poisoned DB. JSON API, versioned under
  `/v1`. Rate limiting: a per-token bucket on authed routes PLUS a coarse per-IP bucket
  in front of the anonymous `/v1/auth/*` mint routes (they do real RSA/DB work with no
  bearer token to key on); both bucket maps sweep idle entries past a TTL once large, so
  they stay bounded under token rotation / IP churn. No analytics; logs are operational
  only (no event payloads in logs).
- Endpoints v1: `POST /v1/auth/apple`, `POST /v1/auth/refresh`, `DELETE /v1/account`,
  `POST /v1/sync` (push+pull in one round-trip), `POST /v1/groups`,
  `POST /v1/groups/join`, `GET /v1/groups/:id` (member day states),
  `POST /v1/groups/:id/nudge`, `GET /v1/entitlement`.
- Tests: auth (JWKS mocked), sync round-trip incl. dedup/replay/two-device merge,
  one-active-challenge conflict, group visibility (member vs non-member), entitlement
  gate on/off. Same bar as the core: fmt, clippy -D warnings, all green in CI.

## Infra & deploy (authored now, applied at the deploy milestone)

Everything per plan.md "Server infrastructure (IaC)" and "GitOps" verbatim (droplet,
volume, reserved IP, firewall-by-tag, monitor alerts, uptime check, R2 buckets, CF DNS
zone, encrypted OpenTofu state in R2, push-based deploys, IMAGE_TAG=git SHA, rollback =
re-run with earlier SHA, litestream restore-before-up guard). **All authored; nothing
applied** — no cloud creds live in this repo.

### The real files

- **`infra/`** — one OpenTofu root module. `versions.tf` (OpenTofu ≥1.12; DO `~>2.93`,
  Cloudflare `~>5.21`), `backend.tf` (S3 backend → R2 with `use_lockfile` + AES-GCM/PBKDF2
  state encryption), `providers.tf`, `variables.tf` (every secret is a no-default var),
  `project.tf`, `network.tf` (VPC, reserved IP, firewall-by-tag), `droplet.tf`,
  `storage.tf` (data volume, `prevent_destroy`), `dns.tf` (CF zone + apex A + CAA + two R2
  buckets + per-bucket scoped tokens), `monitoring.tf` (CPU/mem/disk alerts, `/healthz`
  uptime check), `outputs.tf`, `templates/cloud-init.yaml.tftpl`. Verify locally with
  `tofu fmt`; `tofu validate` runs in CI (Santa SIGKILLs the provider plugins on the Mac).
  `infra/README.md` has the full bootstrap runbook + recreate drills.
- **`deploy/`** — `compose.yml` (drome-server + Caddy + Litestream sidecar; named volumes
  bind onto the mounted data volume), `Caddyfile` (auto-HTTPS for drome.day), `litestream.yml`
  (SQLite → R2), `.env.template` (placeholders; note `DROME_DEV_AUTH` is NEVER set in
  prod), `deploy.sh` (push deploy + the restore-before-up guard).
- **`server/Dockerfile`** — multi-stage: static musl `drome-server` binary → debian-slim
  runtime with a `/healthz` HEALTHCHECK. `.dockerignore` at the repo root (build context is
  the repo root; the server crate has a `../core` path dep).
- **`.github/workflows/infra-ci.yml`** — PR: fmt + init(-backend=false) + validate, plan
  posted as a PR comment; push→main: apply behind the `infra` environment approval; weekly
  drift check opens an issue. **`.github/workflows/server-deploy.yml`** — build+push the
  amd64 image (tagged by git SHA), then SSH-deploy behind the `deploy` environment;
  `workflow_dispatch` inputs `rollback_sha` and `deploy_mode` (normal/fresh/restore).

### Bootstrap checklist for Jacob (run once, at the deploy milestone)

1. **Hand-make the state store** (never managed by the stack it stores): create an R2
   bucket `drome-tofu-state`; create an R2 API token scoped to it; note its S3 **Access
   Key ID** + **Secret Access Key** (secret = `sha256(token value)`). Pick a **state
   encryption passphrase** (≥16 chars) → password manager.
2. **`infra` GitHub environment** (required reviewers = the apply approval). Secrets:
   `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_STATE_ENDPOINT` (`https://<acct>.r2.cloudflarestorage.com`),
   `TF_STATE_ACCESS_KEY_ID`, `TF_STATE_SECRET_ACCESS_KEY`, `TF_STATE_PASSPHRASE`, `DO_TOKEN`,
   `CLOUDFLARE_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `SSH_PUBLIC_KEY`, `DEPLOY_USER_PUBLIC_KEY`,
   `ALERT_EMAIL`. Set repo variable `INFRA_ENABLED=true`.
3. **First apply** (from `infra/README.md`): `tofu init -backend-config=…` → `plan` → `apply`
   (in CI, behind the environment approval). Then set Porkbun's nameservers to
   `tofu output cloudflare_nameservers`, and enter the DNSSEC DS record at Porkbun.
4. **`deploy` GitHub environment.** Secrets: `DEPLOY_HOST` (reserved IP or drome.day),
   `DEPLOY_SSH_KEY` (deploy user's private key; public half was `DEPLOY_USER_PUBLIC_KEY`),
   `DEPLOY_SSH_HOST_KEY` (the droplet's SSH host public key — capture once right after first
   boot with `ssh-keyscan <reserved-ip-or-drome.day>` and paste the line(s); pins the host so
   the piped GHCR token + R2 secret can't be MITM'd. If unset, the first deploy falls back to
   trust-on-first-use and warns),
   `GHCR_PULL_TOKEN` (read:packages PAT), `ACME_EMAIL`, and the litestream R2 creds
   `LITESTREAM_R2_ENDPOINT` / `_BUCKET` / `_ACCESS_KEY_ID` / `_SECRET_ACCESS_KEY` (from the
   tofu outputs). Variables: `DEPLOY_USER=deploy`, `DROME_DOMAIN=drome.day`,
   `DATA_DIR=/mnt/drome-data`, `BETA_ALL_ENTITLED=true`. Set repo variable `DEPLOY_ENABLED=true`.
5. **First deploy:** run `server-deploy` via `workflow_dispatch` with `deploy_mode=fresh`
   (empty volume, brand-new DB). Thereafter every push to main deploys `normal`. A
   from-zero recovery uses `deploy_mode=restore` (litestream restore before start).

**Nameserver-flip timing (plan.md):** do NOT create the free Cloudflare zone more than **28
days** before flipping Porkbun's nameservers, or CF may release it. The **CAA** record
(`issue "letsencrypt.org"`) must be live **before Caddy's first boot** — `.day` is
HSTS-preloaded so cert issuance is on the critical path; the apply creates it, so let the
zone/records settle before the first deploy. Universal SSL adds partner-CA CAA records, so a
strict LE-only lockdown is not available.

## Sequencing

1. **Contracts + scaffold** (this doc, dirs, CI stubs).
2. **Core sync module + server sync/auth skeleton** with the round-trip integration test
   (two simulated devices, one server) — the riskiest math first.
3. **iOS: account UI + SyncEngine + sync status surface** (quiet; "last synced", conflict
   banner). Beta entitlement plumbed.
4. **Groups** (server + iOS group screen + nudges v1).
5. **Deploy milestone**: infra apply (Jacob bootstrap), first deploy to the IaC droplet,
   Litestream verified, drome.day live behind Caddy.
6. **End of phase**: RevenueCat plumbing (not enforced), Health import, reminders, pacing
   coach — each its own reviewed workflow.

Guardrails unchanged from Phase 1 (no analytics, no public surfaces, photos on-device,
honest labels). The server learns as little as possible: no photo bytes, no notes, no
free-text diet descriptions in group payloads.
