# CLAUDE.md — LLM proxy

A thin, **stateless** Cloudflare Worker (TypeScript) between the app and the
Anthropic API. See root `CLAUDE.md` and `docs/ARCHITECTURE.md` §9.

## Why it exists (and what it must NOT become)

An LLM API key can't ship in the app binary. The proxy holds the key, pins
versioned server-side prompts + JSON schemas (so prompt fixes ship without an
app release), and forces schema-valid output. That's it.

**It stores no user data and keeps no conversation history** — that's the
privacy posture from `PLAN.md` §7. Do not add a database, stored chats, or
server-side scheduling. Sync, when it comes, uses CloudKit, not this proxy.

## Files

- `src/index.ts` — the Worker: validates the request envelope, calls Claude with
  single-tool `tool_choice` (forces structured output), shapes the tool input
  into the `{ result }` envelope the Swift `LLMClient` decodes. Stubs (TODO):
  App Attest verification, rate limiting, subscription metering.
- `src/prompts.ts` — per-task system prompts + JSON schemas, keyed by `Task`
  (`interview` / `generatePlan` / `replan` / `coach` / `review`).
- `wrangler.toml`, `tsconfig.json`, `package.json`.

## The contract (must match the Swift side)

Request body (from `App/Goals/Services/LLMClient.swift`):
```
POST /v1/llm
{ task, promptVersion, schemaVersion, repair, payload }
```
Response:
```
{ result: <task-specific structured object> }
```
The shapes of `payload` (per task) and `result` are defined by the Swift types
in `Packages/GoalsCore/Schemas/` and the `LLMClient` request/response structs.
**If you change a schema, change all three: the Swift type, this proxy's schema,
and `MockLLMService`.**

## Rules

- **Always force structured output** via `tool_choice: { type: "tool", name }`
  with a single tool whose `input_schema` matches the Swift `Codable` type. Never
  parse free-form text.
- **Model:** default to the latest, most capable Claude model. Currently
  `claude-opus-4-8` with `thinking: { type: "adaptive" }`. Model IDs are pinned
  here so they change without an app release.
- **Key handling:** the Anthropic key is a Worker secret
  (`wrangler secret put ANTHROPIC_API_KEY`) — never commit it.
- The Swift client does one **decode-repair round-trip** by re-POSTing with
  `repair: true`; the proxy appends a repair instruction to the system prompt.
  Keep that behaviour.

## Develop / deploy

```sh
npm install
npm run typecheck
npx wrangler dev            # local
npx wrangler secret put ANTHROPIC_API_KEY
npm run deploy             # prints the Worker URL → app's Secrets.xcconfig
```

## Recipe: add a task

1. Add the case to `Task` and a `TaskSpec` (system prompt + tool schema +
   `userContent` builder) in `src/prompts.ts`.
2. Shape its result in `shapeResult` in `src/index.ts`.
3. Add the matching method to `LLMService` + `LLMClient` (Swift) and
   `MockLLMService`.
