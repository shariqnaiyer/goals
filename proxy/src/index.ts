// Thin, stateless LLM proxy for the Goals app (docs/PLAN.md §3.2).
//
// Responsibilities — and nothing more:
//   • hold the Anthropic API key (never shipped in the app binary)
//   • pin server-side prompts + schemas by version (so prompt fixes don't need
//     an app release)
//   • force schema-valid structured output via single-tool tool_choice
//   • shape the result into the envelope the Swift LLMClient expects: { result }
//
// It stores NO user data and keeps NO conversation history — the privacy posture
// from the plan. Auth (App Attest), rate limiting and subscription metering are
// stubbed here and noted as the production TODOs.

import { SPECS, Task } from "./prompts";

export interface Env {
  ANTHROPIC_API_KEY: string;
}

const MODEL = "claude-opus-4-8";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

interface RequestBody {
  task: Task;
  promptVersion: string;
  schemaVersion: string;
  repair: boolean;
  payload: any;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST") return json({ error: "POST only" }, 405);
    const url = new URL(request.url);
    if (url.pathname !== "/v1/llm") return json({ error: "not found" }, 404);

    // TODO(production): verify App Attest token from the Authorization header,
    // rate-limit per device, and meter usage against the StoreKit subscription.

    let body: RequestBody;
    try {
      body = await request.json();
    } catch {
      return json({ error: "invalid JSON" }, 400);
    }

    const spec = SPECS[body.task];
    if (!spec) return json({ error: `unknown task ${body.task}` }, 400);

    try {
      const toolInput = await callClaude(env, body, spec);
      const result = shapeResult(body.task, toolInput);
      return json({ result });
    } catch (err: any) {
      return json({ error: String(err?.message ?? err) }, 502);
    }
  }
};

async function callClaude(env: Env, body: RequestBody, spec: typeof SPECS[Task]) {
  const repairNote = body.repair
    ? "\n\nIMPORTANT: your previous output failed to parse. Return ONLY a valid tool call this time."
    : "";

  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01"
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 4000,
      // NOTE: extended thinking is incompatible with a forced tool_choice
      // ("Thinking may not be enabled when tool_choice forces tool use").
      // The app depends on schema-valid structured output (single-tool
      // tool_choice, below), so thinking is intentionally left off.
      system: spec.system + repairNote,
      tools: [spec.tool],
      tool_choice: { type: "tool", name: spec.tool.name },
      messages: [{ role: "user", content: spec.userContent(body.payload) }]
    })
  });

  if (!res.ok) {
    throw new Error(`anthropic ${res.status}: ${await res.text()}`);
  }
  const data: any = await res.json();
  const toolUse = (data.content ?? []).find((b: any) => b.type === "tool_use");
  if (!toolUse) throw new Error("model did not return a tool_use block");
  return toolUse.input;
}

// Map each task's tool input to the { result } shape the Swift client decodes.
function shapeResult(task: Task, input: any): unknown {
  switch (task) {
    case "onboardingTurn":
      return input; // OnboardingTurnResult shape: { state, assistantMessage, choices, stage }
    case "generatePlan":
      return input; // PlanProposal shape
    case "replan":
      return input; // PlanDiff shape
    case "coach":
      return { message: input.message, proposedDiff: input.proposedDiff ?? null };
    case "review":
      return { narrative: input.narrative };
  }
}

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" }
  });
}
