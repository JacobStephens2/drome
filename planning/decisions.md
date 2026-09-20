The app is named Drome. The camel mascot's name is Jerome. It will be served at drome.day - that's the domain name.

Server side service will be a Stephens Page LLC Digital Ocean virtual machine, provisioned by OpenTofu for IaC.

The app environment will have a working Dockerfile and the app will live in and be served from a Docker container.

Photos and backups will be to a Cloudflare R2 bucket, with Litestream to backup the SQLite database.

Porkbun will be the registrar, Cloudflare will be the nameserver, and the app will use push-based GitOps via GitHub Actions. Initially the repo will be private.

Decided 2026-07-04 (Phase 1 kickoff, confirmed by Jacob):
- **drome.day registered** at Porkbun (2026-07-04), A record → 68.183.62.24 (the personal
  stephens.page droplet) as interim parking on Porkbun nameservers. Cloudflare takes over the
  nameservers with the Phase 2 IaC (per plan: create the CF zone no more than ~28 days before
  flipping nameservers at Porkbun).
- Repo: **github.com/JacobStephens2/drome** (private, personal account — no LLC org exists).
- Bundle ID: **day.drome.app** (widget day.drome.app.widget, App Group group.day.drome.app).
- Santa/cargo on this Mac: Jacob extended the Lockdown profile (same day) to allowlist the
  repo's `core/target/(debug|release)/` — plain cargo works in-repo (verified). No further
  Santa changes needed for Phase 1, including week-4 device builds; TestFlight needs only
  App Store Connect access.

Phase 2 kickoff (2026-07-05, confirmed by Jacob):
- Phases restructured: **Phase 2 = server, accounts, sync, groups** (+ Health import,
  reminders, pacing coach); watch/web → Phase 3; Android → Phase 4.
- **Auth: Sign in with Apple** (server verifies Apple identity tokens, issues its own
  session tokens). Email/magic-link joins in Phase 3 with web.
- **Paywall: free beta** — entitlement checks plumbed from day one, a beta flag grants
  all TestFlight users full access; RevenueCat + StoreKit land at end of Phase 2,
  enforced at public App Store launch. Nobody paywalled mid-challenge.
- Dev process per plan.md: all dev on the MacBook (plain `cargo run` for Axum, simulator
  → localhost), no local Docker, CI builds the amd64 image → GHCR, deploy dry-runs to
  stephens.page, real target = the IaC droplet. Infra is authored now, applied when the
  server has something to deploy (bootstrap needs Jacob: DO + Cloudflare tokens, R2
  state bucket, state passphrase).
- **OpenTofu 1.12.3 installed locally** (2026-07-05) at /usr/local/bin/tofu, checksum-verified
  against the official SHA256SUMS, Santa-allowlisted by SHA-256 pin (fa6b1125…eba0; re-pin on
  upgrade). So `tofu fmt/validate/plan` now runs on the Mac — infra/ no longer CI-only.
- **Sign in with Apple capability enabled** on the day.drome.app App ID (Jacob, 2026-07-06) —
  prerequisite for the native iOS auth flow, now cleared. Still later: a Services ID + .p8 key
  (Keys section) for server-side token revocation / account-deletion + Phase 3 web sign-in.
- **OpenTofu providers Santa-allowlisted** (Jacob, 2026-07-06): DO 2.93.0 + Cloudflare 5.21.1
  provider plugins SHA-pinned, so `tofu validate` (verified clean locally) and `tofu plan`
  now run on the Mac. SHA pins hold across re-inits of the lockfile-pinned versions; re-pin
  only on a deliberate provider upgrade. `tofu plan`/`apply` still need the real DO/CF/R2
  credentials in the env.

Product principle (2026-07-07, confirmed by Jacob):
- **Lean into flexibility, trust the honest self-user.** The app is for the user's own use,
  so there's no incentive to game it — favor permissive, useful features over rigid
  correctness / anti-cheat guards, and keep copy confident and light rather than cautionary.
  This is why flexible mode is the default (purist opt-in), why the app is "honest, not
  shaming" (no partial-credit celebration, no streak freezes), and why post-onboarding
  start-date editing ("Change start day" in Settings) is the right call despite renumbering
  days. Exception: genuine safety features stay — e.g. the water anti-chug guard.

Environment (2026-07-20, per Jacob):
- **Jacob's current dev Mac does NOT run Santa.** The Lockdown constraints recorded above
  (allowlisted `core/target/`, SHA-pinned tofu + providers, no brew / no unsigned host
  binaries) were real on the machine used 2026-07-04..07 and stay recorded as history;
  they no longer bind day-to-day work. The repo's workspace target-dir pinning stays —
  harmless, and keeps the tree portable to any future managed machine.