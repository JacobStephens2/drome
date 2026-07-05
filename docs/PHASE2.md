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
target. `tofu` is NOT runnable on this Mac (unsigned binary, Santa) — infra validation
happens in CI only; author locally, validate in the PR loop.

## Sync protocol (the heart — same event-sourcing spine as Phase 1)

Client events are immutable, globally unique by uuid, and additive; revocations and
corrections are themselves events. Therefore **sync = idempotent event exchange**; the
projections never sync, they recompute.

- Server stores per-account event rows: client event fields + `account_id` +
  `server_seq` (monotone per account, assigned on insert) + `device_id`.
- **Push**: client sends events it hasn't had acked (client tracks a local
  `synced_through` watermark over its own event table). Server upserts **dedup by
  uuid** (replays are no-ops), assigns server_seq, acks with the uuids + new seqs.
- **Pull**: client sends its `last_server_seq`; server returns all newer events (any
  device), client applies idempotently (skip uuids it already has), advances cursor.
- Water totals, task states, runs: correct by construction — events merge additively,
  order-independent up to per-day recompute; per-event `logged_at`/`effective_date`
  travel with the event so attribution is identical on every device.
- **Config is NOT events** (challenge settings row, presets, extras): per-slot
  last-writer-wins keyed on `updated_at` (+device_id tiebreak), synced in the same
  round-trip as a `config` block. Goal changes remain events (as-of-day semantics).
- **One active challenge per account** (server-enforced): the first synced active
  challenge wins; a device pushing a *different* active challenge gets it stored
  archived (`sync_conflict` label) and pulls the winner. The client surfaces this
  honestly ("This phone's challenge was archived — your account already has one").
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
  created_at`. Issues an opaque bearer session token (random 256-bit, hashed at rest,
  rotating refresh; `Authorization: Bearer`). No passwords, ever.
- Deleting an account (App Store requirement): `DELETE /v1/account` wipes account rows,
  events, memberships server-side. Local data untouched.

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
  run at startup before serving (single-writer). `/healthz` (used by uptime check + deploy
  gate). JSON API, versioned under `/v1`. Rate limiting: per-token simple token bucket.
  No analytics; logs are operational only (no event payloads in logs).
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
re-run with earlier SHA, litestream restore-before-up guard). Bootstrap checklist for
Jacob when we get there: DO API token, Cloudflare API token, hand-made R2 state bucket +
keys, state passphrase (password manager), GitHub environment secrets (infra / deploy).

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
