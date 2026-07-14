# Plan: A 75 Hard–style Tracker Built for My Sister (and Her Friends)

Sources: [research/description-of-75-hard.md](research/description-of-75-hard.md) (what the program actually is), [research/what-would-make-a-hard75-app-useful.md](research/what-would-make-a-hard75-app-useful.md) (feature research and market landscape), and — primarily — [My sister and her 75 Hard app problem.md](My%20sister%20and%20her%2075%20Hard%20app%20problem.md) (a real user, mid-challenge, with observed workarounds). The canonical short decision log is [decisions.md](JacobStephens2/drome/planning/decisions.md); this plan carries the detail behind those decisions.

## The problem, concretely

My sister is doing 75 Hard with friends right now, and her tooling is four disconnected things: a Google Sheet on her phone for the checklist, a separate water app (which only logs in 16 oz increments, and fills a llama — which she likes), Apple Fitness/Watch for workouts, and a group chat where everyone shares workout screenshots. She looked at the official app and won't pay ~$40/year for what is essentially a checklist. What keeps her going is the satisfaction of checking every box — completing the entire list — plus the program's intensity ("if you drank all but the last ounce, you're not done — drink that final ounce").

Critically, **my sister's group has loosened the rules on purpose**: no restart-from-Day-1 on a missed day, and a "day" is her waking hours (which can roll past midnight), with the sheet's flexibility letting her check off last night's reading this morning. She also *added* a weekly rule of her own.

This validates several findings from the feature research (sleep-anchored day boundaries, retroactive logging grace, container-based water logging, custom tasks as a market gap, subscription resentment, group accountability) — but it **flips one of its defaults**: the research assumed strict-rules-by-default with softer variants opt-in. Real users run it the other way. So:

## Product thesis

**A free, delightful, single app that replaces the spreadsheet + water app + screenshots — flexible by default, with an opt-in "purist mode" that enforces the program as Andy Frisella wrote it.**

Design principles:

1. **Sister-mode is the default; Andy-mode is a setting.** The default experience tracks the challenge the way real groups actually run it. Purist mode (chosen at challenge start) enforces the rules as written and is clearly labeled as such. Finish and share artifacts carry the ruleset label honestly — a flexible-mode Day 75 and a purist Day 75 are both celebrated, but they read differently, so neither devalues the other.
2. **The five tasks are five data shapes** — water is a counter, workouts are timed durations with an outdoor flag, reading is pages against a book, diet is a one-tap attestation, the photo is a capture. No flattening into identical checkboxes (the universal competitor weakness).
3. **The completed day is the emotional core.** Checking the final box of the day should deliver a real hit — "I did something hard" — with a touch of silly riding alongside (the water camel). Celebration is reserved for *complete* days; no confetti for partial credit. Weekly-cadence extras (like the job-application preset) never block the daily completion moment — they bind to the week, get their own smaller moment, and only gate the *weekly* wrap-up.
4. **Freemium: the local app is free forever; server-side features are the paid tier.** A monthly subscription unlocks sync and groups (Phase 2); web access joins the same tier when it ships in Phase 3. Never paywall mid-challenge, never hold data hostage: if a subscription lapses on Day 50, the local app keeps working fully and export always works — only sync/group features pause.
5. **Local-first; data cannot be lost.** Append-only local storage, off-device backup, export always available. Losing Day 60 to a bug or a broken phone is the category's cardinal sin.
6. **Don't use "75 Hard" in the name or store keywords.** Two USPTO registrations (serials 88348904, 88978852 — the latter covering downloadable software) belong to Frisella's 44Seven Media, which ships a competing app. Coined name, nominative fair use only in description text, non-affiliation disclaimer.

## The two modes

**Default (flexible) mode:**
- Missing a day never resets anything. The calendar shows the miss honestly; totals ("62 of 75 days complete, 14-day current run") keep going.
- Day boundary = waking hours: the day ends when you tell it you're done (or a configurable cutoff), not at midnight.
- Retroactive check-off: yesterday stays editable until it's closed out (the "I read last night but fell asleep" case).
- Water goal defaults to one gallon but is adjustable; any-amount logging.
- Custom extra tasks welcome (see MVP item 7).

**Purist mode (opt-in at challenge start, immutable mid-attempt):**
- The rules as written: five tasks daily, restart to Day 1 on any miss — implemented with the research's "restart with dignity" pattern (the failed attempt is archived whole, never erased; lifetime stats persist; the restart flow is designed, not a red X). The attempt model also supports an honorable **"stopped" state for injury/illness**, distinct from "failed" — the research warns that failure-only models push people to train hurt to protect a streak.
- The full fine print surfaced: the chosen diet with **zero cheat meals and zero alcohol**; two 45-minute continuous workouts, one outdoors, with a **minimum** of 3–4 hours between them; one gallon of **plain** water only; 10 **physical** pages of nonfiction (per the official FAQ: self-development or business books, audiobooks don't count, one book at a time); daily progress photo.
- Stricter day-boundary options and a short, watermarked late-log grace window instead of open editing.
- Custom extra tasks don't mix into a purist attempt's verdict — the research is right that bolting unofficial rules onto the strict program dilutes what "finished 75 Hard" means. Extras alongside a purist run are tracked and labeled as exactly that: extras.
- Purist mode is where the research's "referee" ideas live: explainable verdicts and the feasibility engine for the strict constraints (workout-spacing math, latest-possible-start warnings). Deficit-based evening reminders, by contrast, are for everyone — see Phase 2.

One codebase, one rules engine, two rule presets — plus custom presets later (75 Soft etc. are just other rulesets).

## MVP — Phase 1: iOS, local-first, free

Per the source notes, my sister believes her whole group is on iOS, and iOS alone is judged sufficient for them — so: iOS first, and the smallest thing that replaces her sheet and water app. One timing fact shapes this scope: **the group is mid-challenge now**, so the MVP must let someone join at Day N, not just Day 1.

1. **Day board.** Five task tiles (plus opted-in extras), each with its proper input, day counter, "what's left today" at a glance. Completing the last daily task triggers the completion moment — the satisfying, slightly-over-the-top "did something hard" hit.
2. **Water tracking with the camel.** Log any amount; save container presets ("my bottle = 24 oz") for one-tap logging — directly fixing the 16-oz-increment annoyance. The camel fills as the gallon progresses — a camel storing water for a long, hard desert crossing is the app's whole metaphor, and friends teasing each other about overfilled camels is a feature, not a bug. A simple on-pace/behind indicator across waking hours, a "final ounce" nudge honoring the finish-completely ethos — and a **hard-coded anti-chug guard** in all modes (warn when logging implies >~1L in an hour; never encourage late-night catch-up chugging). The research flags this as the program's most acute medical risk, and the final-ounce devotion makes it real for this group.
3. **Water quick-add widget.** Home-screen widget with one-tap container logging. At 6–10 water logs a day, widget-vs-open-the-app is the difference between the app and the spreadsheet; this stays in the MVP ahead of shinier items.
4. **Workouts.** Manual log first: duration + indoor/outdoor flag (+ optional note). Apple Health/Fitness *import* comes in Phase 2 — my sister already tracks workouts on her Watch, and her Apple Activity sharing with friends is a separate social loop we don't need to replace; the goal is just that her Watch workout eventually lands on the board without double entry.
5. **Reading.** Current book + pages read today (10-page target); light one-book-at-a-time support (enforced only in purist mode).
6. **Diet.** One-tap daily attestation against the diet the user names at setup. Deliberately no calorie/macro tracking (per research: off-program and an ED accelerant).
7. **Custom extras, minimal version.** Ship exactly one opt-in preset — **"Apply to a job (1×/week)"**, modeled on a weekly column in a real tracker (the source explicitly allows shipping just this one). Weekly extras show as a week-scoped tile and never block the daily completion moment. The generalized custom-task builder comes later.
8. **Progress photo: check-off only.** A daily done/not-done tile (optionally attaching a photo from the camera). The in-app camera, private on-device photo store, ghost overlay, and timelapse are the fast-follow — the photo pipeline is the research's most sensitive feature and deserves its own careful pass, not a rushed MVP corner.
9. **Share card.** One tap generates a clean, story-sized image of the day — day number, checklist state, streak, **and the day's workouts (duration + outdoor flag)**, since workout screenshots are what the group actually shares today — to drop into the existing group chat. No server, accounts, or feed: the group chat *is* their social platform; meet them there. Cards carry the ruleset label (see principle 1).
10. **Mid-challenge onboarding.** Start a challenge at Day N with a fast backfill grid (a week-per-screen tap grid, not day-by-day forms) so my sister can bring her ~two months of sheet history in by hand in a few minutes. Automated import from her tracker spreadsheet (the source of truth is the Google Sheet, which exports to the .xlsx in research/) is a stretch goal — the backfill grid makes it optional.
11. **Data safety.** Local SQLite with append-only events, JSON/CSV export, and **off-device backup from day one** (iCloud Drive/Files export or CloudKit private DB) with a visible "last backed up" state — a local-only backup doesn't survive a lost phone, and lost-progress is the top competitor complaint.

**Explicitly deferred out of MVP** (fast-follow, in rough order): **purist mode v1** (restart enforcement + attempt archive + fine-print surfacing — the rules-engine abstraction ships in the core from day one, but my sister's group is 100% flexible-mode, so the enforcement UI can follow the TestFlight rather than gate it); photo capture-to-private-store; day-state widget. watchOS (including the quick-add) is deferred to Phase 3 with the rest of the watch app. Spreadsheet import is dropped entirely: the backfill grid makes it unnecessary.

Success criteria: my sister's group switches off the sheet + water app **for the remainder of their current round**, and picks this app for their next round (and their friends' rounds — the 75-day format means the next cohort is never far away); logging any task takes under ten seconds; the completion moment gets a reaction in the group chat; nobody loses data.

## Phase 2: server, accounts, groups

The focus is the server-side core: accounts, sync, and friend groups. Watch and web are deliberately deferred to Phase 3 so Phase 2 ships one thing well.

**Development process (decided 2026-07-05):**

- **All development on the MacBook, none on the stephens.page droplet.** Sync work is tight client-server iteration and the client half needs Xcode: run the Axum server with plain `cargo run` (SQLite file alongside it), point the iOS simulator at localhost, and debug both sides of a sync round-trip on one machine. The droplet is a production box serving live sites - deploy to it, never develop on it.
- **No Docker on the MacBook.** The Mac is Apple Silicon and the deploy targets are x86_64 (stephens.page droplet confirmed: DO Premium AMD), so local `linux/amd64` image builds would run under slow emulation. Nothing in the dev loop needs a container anyway: SQLite is embedded, so there is no database server to spin up.
- **CI builds the production image.** GitHub Actions (native amd64) runs the same `cargo test` as local, builds the Linux container, and pushes it to the registry; deploys pull from there. CI is what keeps Linux parity honest - the artifact that reaches production is the same container no matter where the code was written.
- **Litestream is a production sidecar, not a dev dependency.** Verify R2 replication during deploy testing; the local loop never runs it.
- **Deploy dry-runs go to the stephens.page droplet** (throwaway staging only, per Server infrastructure below); the dedicated LLC-owned IaC-managed droplet is the real target from Phase 2 day one.

- **Accounts + sync** on the dedicated, IaC-managed droplet (Rust/Axum in Docker; see "Server infrastructure" and "GitOps" below). Local-first stays the source of truth; sync is opportunistic. Progress photos stay on-device by default; any photo sync is explicitly opt-in and encrypted.
- **Friend groups.** The live version of what they do by screenshot: each member's day count and today's task states, one-tap nudges, shared start dates. Restart visibility is user-controlled (purist mode) — the research is emphatic that a Day-1 reset must never leak to the group by accident.
- **Apple Health integration:** workout auto-import (duration/outdoor detection) so the Watch workout my sister already records lands on her board automatically.
- **Time-aware reminders for everyone:** deficit-driven ("still open: 40 oz, reading"), quiet when on-pattern, escalating only near the user's own day end; purist mode adds the strict feasibility warnings (workout-spacing deadlines). No shame pushes; late-evening water reminders switch to the anti-chug message instead of cheering a catch-up.
- **Full water pacing coach:** the MVP's simple pace line grows into per-hour pacing with the user's waking window.

## Phase 3: watch, web, broaden

- **watchOS app:** water logging and task check-off at the wrist; the 45-minute workout timer for purist mode.
- **Web access** (read + basic entry) for desk hours.
- **Photo timelapse and milestone reviews** (25/50/75) — the delayed-reward payoff.
- **Attempt analytics** (purist): cross-attempt patterns ("both attempts died on Saturdays").
- **More rulesets:** 75 Soft/Medium presets, Live Hard phases, a general custom-challenge builder.
- **After Day 75: a continuation story.** My sister's underlying motivation is habit formation ("14 or 21 days isn't enough") — the research flags post-challenge retention as an industry-wide gap. At minimum: a maintenance mode that keeps the daily board with the user's own chosen task set after a finished challenge, and an easy "start the next round" flow.

## Phase 4: Android

- **Android (native Kotlin) + Wear OS**, reusing the shared core — the research identifies Android as the market's biggest open lane, mixed-platform groups need it, and interest beyond the iOS circle is plausible (the source's own guess).

Deliberately not planned: public feeds, leaderboards, calorie tracking, verification theater. (Full rationale in the research doc's anti-features section.)

## Design

**The camel is the brand.** It's the water mascot, the app icon, and the tone-setter for the whole visual identity: an animal built for doing something long and hard — storing up water, crossing the desert, unbothered by conditions. The design language should carry that dual register the product thesis demands: **intense, disciplined, high-performance self-improvement** as the base note (strong type, high contrast, desert palette, a UI that feels like gear rather than a toy), with the camel supplying the **touch of silly** (it fills up as you drink; it reacts to the completion moment). The camel is named **Jerome** (decided 2026-07-05: my sister misheard "Drome" as "Jerome" and loved it — the rhyme keeps the brand link, and the primary user coining the mascot's name is worth more than one-name purity; Humphrey was the runner-up). Design work starts in week 1 alongside the core, because the completion moment and Jerome-the-camel are feel-driven and need iteration time.

## Tech stack

- **Shared logic core: Rust** — the user's stated preference and established pattern (Rust core + native clients, offline-first SQLite + sync, per prior projects). The core owns the rules engine (both modes), day-boundary/waking-hours math, the append-only event log, day projections, and streak/attempt logic. Exposed to Swift (and later Kotlin) via **UniFFI**; compiled to WASM later for web. Property-test the day-boundary math (sleep-anchored days, past-midnight rollover, DST, travel).
- **iOS/watchOS: native SwiftUI.** The research is unambiguous that this app lives on the OS-integration surface — HealthKit, WidgetKit, watch apps, notification actions — exactly where Capacitor/Dioxus/RN/Flutter are weakest. Capacitor would buy velocity on the checklist UI and then tax every feature that matters (widgets, watch, Health). Given the Rust core carries the logic, the Swift layer is mostly views — native is the right call.
- **Server (Phase 2): Rust + Axum in Docker** on a dedicated, IaC-managed DigitalOcean droplet (see "Server infrastructure" below; the personal stephens.page droplet remains available for throwaway experiments, but the IaC makes the dedicated LLC-owned box cheap enough to use from Phase 2 day one). SQLite in WAL mode storing the same event-log shape as the client; sync = event upload/merge (per-slot last-writer-wins; water counters merge additively); Litestream replicating continuously to R2; photos direct to R2 via presigned URLs so blobs never touch the droplet.
- **Web (Phase 3):** decide between Leptos (full-Rust, reuses core natively) and TypeScript + wasm-bindgen around the core (bigger ecosystem). Defer the decision; the core compiles to WASM either way.

### Server infrastructure (IaC)

Decided after a fact-checked comparison of DigitalOcean, AWS (EC2 and Lightsail), and Hetzner (July 2026 pricing verified): **DigitalOcean droplet, defined end-to-end in OpenTofu.** DO won on all-in cost (~$8–15/mo: $7 Premium AMD 1 GB NVMe droplet or $12–14 for 2 GB, +$1 volume, free assigned reserved IP, free uptime check; DO's droplet-backup surcharge is deliberately skipped — it snapshots only the disposable boot disk and never covers attached volumes, and the real data safety is Litestream→R2 plus optional volume snapshots), Terraform-provider quality (partner-tier, weekly releases, first-class monitoring/uptime resources that Lightsail and Hetzner can't express in IaC), config-surface simplicity (~15 resources, no VPC/IAM ceremony), and existing operational familiarity. AWS EC2 is ~2× the cost after the T4g trial cliff (Jan 2027) with 3× the config, plus the $3.65/mo IPv4 charge; Lightsail is a fine runner-up with no advantage over DO; Hetzner's US pricing tripled in 2026 and its recreate-forfeits-grandfathered-pricing billing is uniquely hostile to destroy-and-recreate IaC.

- **Tool: OpenTofu 1.12+** (not Terraform — not for legal reasons; BSL permits this use. The genuine differentiators are OpenTofu's native state encryption and the MPL license; Terraform 1.10+ matches the S3 `use_lockfile` locking, so that alone wouldn't decide it). One root module in the repo (`infra/`).
- **State:** OpenTofu S3 backend pointed at a dedicated R2 bucket (`use_lockfile = true` — R2 supports the conditional writes), with the `encryption` block (AES-GCM, PBKDF2 passphrase kept in the password manager — state is unrecoverable without it). The state bucket and its token are bootstrapped once by hand and never managed by the stack they store.
- **Resources:** droplet (`monitoring = true` so the metrics agent feeds the alerts; minimal cloud-init `user_data`: docker + compose, mount the data volume — attached via the droplet's `volume_ids` so it exists at first boot rather than racing cloud-init — and create the deploy user with its public key; rotating that key edits cloud-init and recreates the droplet, which is acceptable because a droplet recreate is designed to be a non-event), tag, project, VPC, reserved IP + assignment, block-storage volume for the SQLite/Litestream data dir (with optional volume snapshots), cloud firewall attached **by tag** (inbound 22/80/443, outbound all), monitor alerts (CPU/mem/disk), uptime check on `/healthz`, SSH key. Cloudflare provider (v5, **pinned ≥5.21** — machine-generated, occasionally rough) for the two R2 buckets (photos, litestream) + scoped tokens (note: the S3 secret key is `sha256(token value)`), **and the drome.day DNS zone** — decided after a fact-checked comparison: Porkbun stays registrar; Cloudflare (free plan) hosts the nameservers. Rationale: the official cloudflare provider is already in the stack (vs a single-maintainer community Porkbun provider), zone-scoped tokens keep DNS out of the DO token's blast radius, future R2 custom domains require the zone in the same Cloudflare account, and DNSSEC is free (enable in Cloudflare, one DS entry at Porkbun). Execution notes: don't create the free zone more than 28 days before flipping nameservers at Porkbun; put the CAA record (`issue letsencrypt.org`) in place before Caddy's first boot (.day is an HSTS-preloaded TLD, so cert issuance is on the critical path); accept that Universal SSL silently adds partner-CA CAA records, so a strict LE-only CAA lockdown isn't available.
- **Sharp edges designed around:** `user_data` is ForceNew (any cloud-init edit recreates the droplet — hence data on the volume, address on the reserved IP, firewall by tag, so a recreate is a non-event); DO's cloud firewall is deny-by-default once rules exist, and — usefully — Docker's iptables port-publishing cannot bypass it the way it punches through ufw, so the cloud firewall is the only firewall.
- **Out of IaC scope:** app deploys (CI, see GitOps), Caddy's ACME certs (live on the volume), SQLite bytes and Litestream operation (runtime), and secret *values* (injected by CI; hence encrypted state).

### GitOps

Git is the single source of truth for everything the server is and runs; the droplet holds no configuration that isn't in the repo. **Push-based** GitOps via GitHub Actions — ArgoCD/Flux are rejected (a Kubernetes control plane heavier than the app), and poll-based agents like Watchtower are rejected (nondeterministic deploy timing, can't sequence a migration with its rollout; revisit only if this ever becomes a fleet).

- **Repo layout (monorepo, private initially):** `core/` (shared Rust), `server/`, `ios/`, `infra/` (OpenTofu), `deploy/` (compose.yml, Caddyfile, cloud-init template, .env template). Path-filtered workflows so an iOS commit doesn't trigger a server deploy. A private repo means private GHCR packages — the read-only pull token in the deploy secrets covers that.
- **Infra pipeline:** PR → `tofu fmt/validate/plan`, plan posted as a PR comment → merge to main → `tofu apply` in Actions behind a GitHub *environment* with manual approval (removable later). A weekly scheduled `tofu plan -detailed-exitcode` catches drift and opens an issue if the live infra no longer matches git.
- **App pipeline:** merge → build the musl binary + docker buildx → push to GHCR tagged with the **git SHA** (never `:latest`). The deploy job SSHes as a dedicated `deploy` user (key only in Actions secrets; root login off; docker-group membership makes it root-equivalent, so the separation is operational hygiene rather than a security boundary), rsyncs `deploy/`, writes `.env` from environment secrets **including `IMAGE_TAG=<sha>`** — compose.yml references `${IMAGE_TAG}`, since a commit can't pin its own SHA; the Actions run records what's live — logs into GHCR with a read-only pull token, runs `docker compose pull && up -d`, then curls `/healthz` and fails loudly if unhealthy. Schema migrations are embedded in the server binary and run at startup before serving (single-writer SQLite makes this safe) — which is exactly the migration-with-rollout sequencing Watchtower couldn't provide. **Rollback = re-run the deploy workflow with an earlier SHA** (a `workflow_dispatch` input; the old image already exists in GHCR, no rebuild); deploy history is the Actions log.
- **Secrets:** GitHub Environments hold the two secret sets — `infra` (DO token, Cloudflare token, the hand-bootstrapped R2 state-bucket access keys, the state passphrase, and the Porkbun API key if that DNS option wins) and `deploy` (SSH key, read-only GHCR pull token, app secrets → written to the box's `.env` at deploy). Nothing secret is committed; SOPS+age is the upgrade path if secrets ever need to live in-repo.
- **Recreate drills** (the whole point) — two distinct scenarios. *Droplet recreate* (the common case, e.g. a cloud-init edit): the volume, reserved IP, and DNS all survive; re-run the deploy workflow and that's it — no restore involved. *Full from-zero* (disaster or migration): `tofu apply` → cloud-init bootstraps docker → **`litestream restore` onto the empty volume first**, then the deploy workflow — the deploy script refuses to `up -d` against an empty data dir without an explicit restore-or-fresh flag, so a blank SQLite file never silently starts a new Litestream generation over the good replica → the new reserved IP means DNS *does* change in this scenario (one record update — or zero, if the DNS-in-IaC option is chosen). The from-zero path doubles as the quarterly restore drill.
- **iOS is not GitOps:** TestFlight/App Store releases are tag-driven CI (fastlane or Xcode Cloud) in their own lane.

### Data model sketch

- `challenge`: ruleset (flexible | purist | custom), start date (may be in the past — mid-challenge onboarding), day-boundary policy, water goal, diet description, extra-task definitions (daily or weekly cadence).
- `event` (append-only): logged-at + effective-at timestamps, kind (`water_add(oz)`, `workout(start, duration, outdoor)`, `reading(book, pages)`, `diet_ok`, `photo(ref)`, `extra_done(task)`, `day_closed`), payload.
- `day` (projection, never stored authoritatively): tasks' completion state per the challenge's boundary policy and ruleset.
- `attempt` (purist): archive linking a challenge's runs, with end state (**completed | failed | stopped-medical**), failure day/task/reason.

## Name and legal

**Decided: the app is "Drome"** (from *dromedary* — the camel connection is a reveal, not a pun); **the camel is named Jerome** (updated 2026-07-05 — see Design). Collision research found no fitness/habit/tracker app named Drome; a web search surfaced no existing "Drome" software trademark, but the proper USPTO (TESS) search happens in the counsel pass before public launch. Runners-up, kept for reference in case counsel kills Drome: **Bactrian** (two humps = two-a-day workouts; an unrelated indie game studio shares the word) and **NotSoft** (no collision found). Eliminated by collision research: **Caravan** (a CARAVAN Wellness app exists — same category), **Camelo/Kamelo** (established scheduling SaaS), **Gobi** (parked premium domain, prior app history). Avoid anything near **CamelBak** (hydration-products trademark) and **Forge** (existing 75 Hard/Soft tracker).

**Domain: drome.day** (available at Porkbun, $11 buy-and-renew — register it). It reads as "Drome, daily," which is the product in two words, and it serves the site, support email, and universal links. drome.app and drome.com are taken by unrelated parties. Backups if ever needed: getdrome.com, dromeapp.com, joindrome.com (nice for group invite links later).

Zero use of "75" + "Hard" together anywhere in name/subtitle/keywords; the App Store description can use "works with 75-day challenges like 75 Hard®"-style nominative references only if counsel approves; ship the non-affiliation disclaimer regardless. A light onboarding note ("this program is intense — the program's own creator says consult a physician first") covers the safety baseline without nannying; the anti-chug guard ships in all modes from day one, and photos stay private by default when capture arrives.

## Business setup, payments, and deployment

- **Entity and rails (already in place):** Stephens Page LLC (single-member; see github.com/JacobStephens2/stephens-page-llc/business-identity.md), with Mercury banking and a connected Stripe account. Apple Developer ID **LHY8W725A8**; distribution via TestFlight for the MVP, App Store at public launch.
- **Model:** freemium. The local app — full challenge tracking, camel, widgets, backfill, export — is free forever with no payments code in the MVP at all. The **monthly subscription** arrives with Phase 2 and gates the server-side features: sync/backup across devices and friend groups (web access joins the same entitlement when it ships in Phase 3). A lapsed subscription pauses sync but never the local app or export (principle 4).
- **Payments plumbing:** in-app subscriptions on iOS must go through Apple IAP/StoreKit. **RevenueCat is a good fit** for this setup: it wraps StoreKit (and later Google Play Billing for Android), *and* supports Stripe as a store — so a future web checkout via the existing Stripe account and the iOS subscription resolve to one entitlement, with RevenueCat as the single source of truth the Axum server can verify. Start with RevenueCat + StoreKit in Phase 2; add the Stripe/web billing path when web access ships. (Free MVP first also means App Review's first look at the app has no purchase surface to object to.)

## Sequencing

1. **Weeks 1–2:** Rust core (event log, flexible-mode ruleset, waking-hours day boundary, projections) + UniFFI bindings + SwiftUI skeleton: day board, water logging + pace line + anti-chug guard, local persistence. Camel art and icon start now in parallel — "impactful but a touch silly" is a feel that needs iteration time.
2. **Weeks 3–4:** remaining task tiles, the job-application weekly preset, completion moment, share card, mid-challenge backfill grid, export + off-device backup, water widget. **TestFlight to my sister's group** (Apple Developer ID LHY8W725A8 is already in place).
3. **Fast-follow while they use it:** purist mode v1 (restart enforcement, attempt archive, fine print), photo capture-to-private-store, day-state widget — reprioritized by the group's actual feedback. (watchOS moved to Phase 3.) The completion moment and mascot especially want playtesting.
4. **Phase 2 (server/groups/Health import)** once the group has validated the solo core — matching the research's "earn trust with the solo experience first" ordering.

The 4-week window is deliberately tight because my sister's current round is finite: better to put water + board + backfill in her hands at week 4 than everything at week 10.

## Decided (was: open questions)

- **Name: Drome** (counsel/TESS check before public launch); runners-up Bactrian, NotSoft held in reserve.
- **Domain: drome.day** — $11 buy-and-renew at Porkbun.
- **Mascot: a camel named Jerome** (renamed 2026-07-05; was Drome) — the camel is the app icon and design anchor (see Design).
- **Watch quick-add: fast-follow**, not MVP.
- **Spreadsheet import: dropped** — the backfill grid covers it.
- **Monetization: freemium** — local free forever, monthly subscription for server features (see Business setup).
- **Deployment: TestFlight** under the existing Apple Developer ID (iOS); **server infrastructure: DigitalOcean + OpenTofu IaC with push-based GitOps** via GitHub Actions + GHCR (see Tech stack); **repo private initially**.
- **DNS: Porkbun stays registrar; Cloudflare (free plan) hosts the nameservers** — zone managed via the cloudflare provider already in the stack (see Server infrastructure for rationale and execution notes).

## Still open

- ~~**Register drome.day** at Porkbun~~ — done 2026-07-04; A record parked at the stephens.page
  droplet (68.183.62.24), Porkbun nameservers until the Phase 2 Cloudflare/IaC move.
- **Counsel pass on "Drome"** (TESS search + store listing review) before public launch — TestFlight to the group doesn't need to wait for it.
- **Subscription price point** for Phase 2 (decide when server costs are real; the only constraint is principle 4 — lapse never breaks the local app).
