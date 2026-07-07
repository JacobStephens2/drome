# Drome (75 Hard tracker) — project folder

Planning and build workspace for **Drome**, a free, local-first iOS tracker for the 75 Hard challenge, built for my sister and her friends. The app and domain are Drome (drome.day); the camel mascot is **Jerome** (renamed 2026-07-05).

## Folder guide

| File / dir | What it is |
|---|---|
| [decisions.md](decisions.md) | **Canonical short decision log.** Name, domain, hosting, GitOps, repo privacy. |
| [plan.md](75hard/plan.md) | The full plan: product thesis, two modes, MVP scope, phases, tech stack, IaC, GitOps, legal. |
| [phase-1-build-brief.md](phase-1-build-brief.md) | **Entry point for the Phase 1 build agent** — scope, machine constraints, check-in points. |
| [75-hard-app/](75-hard-app/) | Build workspace (has its own CLAUDE.md). The private `drome` repo lives here. |
| [My sister and her 75 Hard app problem.md](My%20sister%20and%20her%2075%20Hard%20app%20problem.md) | The primary user's observed needs — design tiebreaker. |
| [research/description-of-75-hard.md](research/description-of-75-hard.md) | What the 75 Hard program actually is (fact-checked). |
| [research/what-would-make-a-hard75-app-useful.md](research/what-would-make-a-hard75-app-useful.md) | Feature research, market landscape, binding anti-features list. |
| [research/perplexity/](research/perplexity/) | External research reports (merged into the docs above). |

## Status (2026-07-04)

- **Phase 1 MVP built (2026-07-04/05)** — full iOS app + Rust core + widget, adversarially
  reviewed (23 confirmed findings fixed), verified on the simulator, CI green. Repo:
  github.com/JacobStephens2/drome (private). Remaining for week 4: camel art/app icon,
  TestFlight (needs App Store Connect access); purist-mode UI is the planned fast-follow.
- drome.day registered at Porkbun (2026-07-04), parked at the stephens.page droplet for now.
- Not yet done: counsel/TESS pass on the "Drome" name (needed before public launch, not before TestFlight); camel art direction.
