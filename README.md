# goals

A native iOS app that acts as an intelligent, adaptive goals system: it turns vague aspirations into concrete plans through a friendly onboarding conversation, breaks goals into milestones and scheduled tasks, tracks progress via chat and a structured Today view, and renegotiates the plan based on how you're actually doing — while respecting constraints like work hours and sleep.

## Documentation

- **[CLAUDE.md](CLAUDE.md)** — start here: map, build/verify commands,
  invariants, and recipes (also auto-read by Claude Code; nested `CLAUDE.md`
  files live in each subtree).
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — layering, modules, data-flow
  walkthroughs, concurrency model.
- **[docs/STATUS.md](docs/STATUS.md)** — what's done / stubbed / next, with a
  prioritised backlog. **Pick up work here.**
- **[docs/PLAN.md](docs/PLAN.md)** — the product & technical plan (the "why").
- **[SETUP.md](SETUP.md)** — build & run instructions.

## Status

A working implementation of the plan is in progress:

- **`Packages/GoalsCore/`** — the pure-Swift domain layer (value-type models, the
  deterministic two-layer scheduler, plan validation/mutation, performance
  analysis, the LLM `PlanDiff` contracts, and a validate-and-retry replan loop),
  with XCTest coverage. Compiles and tests on any platform via `swift test`.
- **`App/Goals/`** — the SwiftUI + SwiftData app: conversational onboarding,
  Today / Goals / Coach screens, the hybrid-chat plan cards, the weekly review,
  settings, and local notifications. Runs offline against a built-in
  `MockLLMService` (no backend required).
- **`proxy/`** — a thin Cloudflare Worker that holds the LLM key and returns
  schema-constrained structured output for the live coach.

The app is iPhone-first, local-first, and built around adapting plans to how you
actually do — not guilt-tripping you with overdue badges.
