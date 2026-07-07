# Drome — planning & design docs

Product-planning and design workspace for **Drome**, a free, local-first iOS
tracker for the 75-day challenge, built for my sister and her friends. The app and
domain are Drome (drome.day); the camel mascot is **Jerome**.

These planning docs live in the same repo as the code — the app / server / infra
source is in the repo root (`../`).

## What's here

| File / dir | What it is |
|---|---|
| [plan.md](plan.md) | The full plan: product thesis, two modes, MVP scope, phases, tech stack, IaC, GitOps, legal. |
| [decisions.md](decisions.md) | **Canonical short decision log** — name, domain, hosting, GitOps, auth, phase order. |
| [drome-specs.md](drome-specs.md) | Assorted product spec notes (water/Jerome UI, task toggles, reset flow). |
| [phase-1-build-brief.md](phase-1-build-brief.md) | The Phase 1 build brief — scope, machine constraints, check-in points. |
| [My sister and her 75 Hard app problem.md](My%20sister%20and%20her%2075%20Hard%20app%20problem.md) | The primary user's observed needs — the design tiebreaker. |
| [research/description-of-75-hard.md](research/description-of-75-hard.md) | What the 75 Hard program actually is (fact-checked). |
| [research/what-would-make-a-hard75-app-useful.md](research/what-would-make-a-hard75-app-useful.md) | Feature research, market landscape, and the binding anti-features list. |
| [research/perplexity/](research/perplexity/) | External research reports (merged into the docs above). |

## Where the rest of the project lives (repo root, `../`)

- **Code** — `../core` (Rust rules engine), `../ios` (SwiftUI app + widget), `../server` (Axum), `../infra` (OpenTofu), `../deploy` (compose / Caddy / Litestream + `../deploy/web` marketing site).
- **Technical contracts** — [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) (Phase 1) and [`../docs/PHASE2.md`](../docs/PHASE2.md) (Phase 2).
- **Current status** — [`../status.md`](../status.md).
