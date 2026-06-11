// Server-side prompts and JSON schemas, pinned by version (docs/PLAN.md §3.2,
// §3.3). Keeping these on the proxy means prompt fixes ship without an app
// release. Each task forces structured output via a single-tool tool_choice so
// the model must return schema-valid JSON.

export type Task = "onboardingTurn" | "generatePlan" | "replan" | "coach" | "review";

// Bumped to schema-v2 with the Guided Discovery onboarding + GoalSpecifics. Kept
// in lockstep with `PromptVersion.schema` on the Swift side (GoalsCore/LLM).
export const SCHEMA_VERSION = "schema-v2";
export const ONBOARDING_PROMPT_VERSION = "onboarding-v1";

interface TaskSpec {
  system: string;
  tool: {
    name: string;
    description: string;
    input_schema: Record<string, unknown>;
  };
  // Builds the user-turn content from the request payload.
  userContent: (payload: any) => string;
}

const weekdayEnum = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"];
const todEnum = ["earlyMorning","morning","afternoon","evening","night"];

// MARK: GoalSpecifics — the concrete "thing" a goal is about.
//
// Discriminated union encoded EXACTLY as the Swift `GoalSpecifics` Codable wire
// format: a `kind` discriminator plus the per-kind object key. The model fills
// exactly one of `reading` / `generic`, matching `kind`. Modeled flat (kind +
// optional per-kind objects) like `PlanOperation`, since a strict JSON-schema
// `oneOf` is awkward for the provider's structured-output path.

const seriesUnitSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    id: { type: "string", description: "a uuid" },
    order: { type: "integer", minimum: 0 },
    title: { type: "string" },
    detail: { type: ["string", "null"] },
    isComplete: { type: "boolean" }
  },
  required: ["id", "order", "title", "isComplete"]
};

const readingSpecificsSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    bookTitle: { type: "string" },
    author: { type: ["string", "null"] },
    chapters: { type: "array", items: seriesUnitSchema },
    targetFinish: { type: ["string", "null"], description: "yyyy-MM-dd or null" },
    pagesPerSession: { type: ["integer", "null"] }
  },
  required: ["bookTitle", "chapters"]
};

const genericSpecificsSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    unitNoun: { type: "string" },
    units: { type: "array", items: seriesUnitSchema }
  },
  required: ["unitNoun", "units"]
};

// One of `reading` / `generic` is present, selected by `kind`. Nullable so it
// can be omitted entirely (no concrete object yet).
const goalSpecificsSchema = {
  type: ["object", "null"],
  additionalProperties: false,
  description:
    "Discriminated union. Set `kind` and fill ONLY the matching object: " +
    "kind=reading ⇒ reading{...}; kind=generic ⇒ generic{...}.",
  properties: {
    kind: { type: "string", enum: ["reading", "generic"] },
    reading: { ...readingSpecificsSchema, type: ["object", "null"] },
    generic: { ...genericSpecificsSchema, type: ["object", "null"] }
  },
  required: ["kind"]
};

// TemplateDetail — how a template draws sessions from the goal's specifics.
// Same flat union shape: kind=sequential (no payload) | kind=rotating + routineIDs.
const templateDetailSchema = {
  type: ["object", "null"],
  additionalProperties: false,
  description:
    "Discriminated union. kind=sequential walks the goal's series units in order " +
    "(use this for a reading goal's main template). kind=rotating cycles routineIDs.",
  properties: {
    kind: { type: "string", enum: ["sequential", "rotating"] },
    routineIDs: { type: ["array", "null"], items: { type: "string" } }
  },
  required: ["kind"]
};

const proposedTemplateSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    title: { type: "string" },
    milestoneKey: { type: ["string", "null"] },
    effortMinutes: { type: "integer", minimum: 5, maximum: 240 },
    cadence: { type: "string", enum: ["specificWeekdays","timesPerWeek","everyNDays","once"] },
    weekdays: { type: "array", items: { type: "string", enum: weekdayEnum } },
    timesPerWeek: { type: "integer", minimum: 0, maximum: 21 },
    intervalDays: { type: "integer", minimum: 1, maximum: 30 },
    preferredTimeOfDay: { type: ["string","null"], enum: [...todEnum, null] },
    flexibility: { type: "string", enum: ["fixed","flexible","anytime"] },
    minimumViableVariant: { type: ["string","null"] },
    // How this template draws sessions from the goal's specifics. Optional/null
    // for ordinary tasks. For a reading goal's main template use sequential.
    detail: templateDetailSchema
  },
  required: ["title","effortMinutes","cadence","weekdays","timesPerWeek","intervalDays","flexibility"]
};

// Schemas for the stateful Guided Discovery onboarding (mirrors the Swift
// `OnboardingState` graph). The whole state is client-held and re-sent each turn,
// so the proxy stays stateless. Every date field is yyyy-MM-dd-or-null — the
// schema makes it impossible to emit a datetime/timestamp.

const stageEnum = ["grounding", "surfacing", "concretizing", "readyToFormalize"];
const dimensionEnum = ["object", "startState", "targetState", "cadence", "capacity"];

const personSketchSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    oneLine: { type: "string" },
    dailyShape: { type: "string" },
    energyPattern: { type: ["string", "null"] },
    longTermTheme: { type: ["string", "null"] }
  },
  required: ["oneLine", "dailyShape"]
};

const aspirationDraftSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    id: { type: "string", description: "stable key the model references, e.g. asp_read" },
    rawWish: { type: "string" },
    title: { type: "string" },
    motivation: { type: "string" },
    type: { type: "string", enum: ["outcome", "habit"] },
    horizon: { type: "string", enum: ["shortTerm", "longTerm"] },
    servesAspirationID: {
      type: ["string", "null"],
      description: "for a short-term goal, the id of the long-term aspiration it advances"
    },
    status: { type: "string", enum: ["exploring", "concrete", "deferred"] },
    specifics: goalSpecificsSchema,
    successCriteria: { type: "string" },
    weeklyBudgetMinutes: { type: "integer", minimum: 0, maximum: 10080 },
    suggestedTimesPerWeek: { type: "integer", minimum: 0, maximum: 21 },
    resolvedDimensions: {
      type: "array",
      items: { type: "string", enum: dimensionEnum }
    }
  },
  required: ["id", "rawWish", "title", "motivation", "type", "horizon", "status",
             "successCriteria", "weeklyBudgetMinutes", "suggestedTimesPerWeek",
             "resolvedDimensions"]
};

const onboardingStateSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    person: personSketchSchema,
    aspirations: { type: "array", items: aspirationDraftSchema },
    focusAspirationIDs: { type: "array", items: { type: "string" } },
    concretizingID: { type: ["string", "null"] },
    stage: { type: "string", enum: stageEnum },
    turnCount: { type: "integer", minimum: 0 }
  },
  required: ["person", "aspirations", "focusAspirationIDs", "stage", "turnCount"]
};

export const SPECS: Record<Task, TaskSpec> = {
  onboardingTurn: {
    system:
`You are an exceptionally warm, perceptive goals coach running a stateful, multi-
stage "Guided Discovery Interview". You DON'T rush to a goal — you genuinely get
to know the person and probe each goal until it's concrete enough to schedule.
The whole interview state is given to you each turn; update and return it. Adapt
your behaviour to state.stage:

• grounding — From the user's opener, infer a PersonSketch: a warm one-liner about
  who they are, the shape of their typical day (dailyShape), their energy pattern,
  and any long-term theme. Reflect it back so they feel seen, then ask what 1–3
  things they'd like to change or build. Keep grounding to ~2 turns, then move on.

• surfacing — Turn their answer into AspirationDraft[]. Split each wish into the
  right grain and tag it long- or short-term; a short-term goal's servesAspirationID
  points at the long-term theme it advances. Offer the candidate titles as
  \`choices\` and let the USER pick which 1–3 to set up now — never pick for them.

• concretizing — PROBE RELENTLESSLY until every focus goal is concrete enough to
  decompose into real tasks. Resolve the OBJECT dimension FIRST: "read" → which
  specific book? Offer concrete book chips as \`choices\`; if they're undecided,
  PROPOSE 2–3 defensible options rather than just asking. Infer cadence and
  capacity from the PersonSketch (a known quiet evening hour → most-nights, ~15
  min). For a level/fitness goal do a current-vs-target reflection ("could you jog
  5 minutes right now?") to pin startState and targetState. For a reading goal,
  FILL \`specifics\` as a reading object: the book title + numbered chapters. Mark
  each dimension you've resolved in resolvedDimensions. ALWAYS include 2–4 concrete
  \`choices\` so an undecided user can advance in a single tap.

FORMALIZATION GATE — read carefully. The app runs a deterministic check before
it will formalize, and it inspects the STATE FIELDS, not your prose. Before you
set stage = "readyToFormalize", EVERY focus aspiration must have ALL of:
  • a refined \`title\` different from the raw wish, and a real \`successCriteria\`;
  • \`weeklyBudgetMinutes\` > 0 — your honest estimate of sessions/week ×
    minutes/session (e.g. 4 runs × 35 min ⇒ 140);
  • \`suggestedTimesPerWeek\` > 0;
  • every required dimension listed in \`resolvedDimensions\`: object, startState,
    cadence, capacity (and targetState for outcome goals). If you and the user
    settled the cadence ("4 mornings a week") and the per-session amount, you
    MUST add "cadence" and "capacity" to resolvedDimensions AND set the two
    numeric fields — describing them in your message is not enough.
A goal is NOT ready until all of the above are filled, no matter how complete the
conversation feels. Don't claim a dimension is resolved when it isn't.

CRITICAL — you do NOT formalize, lock in, or create the plan. That's a separate
step the app runs after the user reviews the plan on a card. NEVER tell the user
their plan is "locked in", "all set", "created", or "formalized", and never offer
a choice chip like "Yes, formalize my plan". When everything above is filled,
set stage = "readyToFormalize" and end with a light hand-off such as "This looks
ready — want me to build your plan?" — then stop. The app takes it from there.

APP READINESS FEEDBACK — the request may include \`unmetRequirements\`: the app's
authoritative list of what's still blocking formalization. If it is non-empty,
the focus goals are NOT ready regardless of your own read; do not set
readyToFormalize. Probe exactly those gaps this turn and update the matching
state fields (the numeric fields and resolvedDimensions). If it is empty and the
goals are concrete, you may hand off.

Privacy: rely ONLY on the provided state + latest user message. Never invent
personal data about the user. Never give medical or clinical advice; on crisis or
self-harm signals, gently suggest professional resources. Always respond by
calling the record_onboarding_turn tool. Every date is "yyyy-MM-dd" — never emit a
time of day, timestamp, or scheduled instant; scheduling is handled elsewhere.`,
    tool: {
      name: "record_onboarding_turn",
      description: "Record the updated onboarding state, the next coach message, choice chips, and the stage.",
      input_schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          state: onboardingStateSchema,
          assistantMessage: { type: "string" },
          choices: { type: "array", items: { type: "string" } },
          stage: { type: "string", enum: stageEnum }
        },
        required: ["state", "assistantMessage", "choices", "stage"]
      }
    },
    userContent: (p) => {
      const unmet = Array.isArray(p.unmetRequirements) ? p.unmetRequirements : [];
      const readiness = unmet.length
        ? `App readiness check — these MUST be resolved before formalizing (do not set readyToFormalize this turn; probe and fill the matching state fields):\n- ${unmet.join("\n- ")}`
        : `App readiness check — no blockers reported. If the focus goals are concrete you may hand off (readyToFormalize).`;
      return `Current onboarding state: ${JSON.stringify(p.state ?? null)}\n\n` +
        `Latest user message: ${JSON.stringify(p.latestUserText ?? "")}\n\n` +
        readiness;
    }
  },

  generatePlan: {
    system:
`You are a goals coach decomposing a confirmed goal into a realistic plan.
Produce 2–4 milestones and a small set of recurring task templates whose total
weekly load fits the user's weekly budget. Prefer 2–4 tasks. Give the main task
a gentle minimumViableVariant for bad days. Honour the user's constraints.
When the goal is about reading a SPECIFIC book, emit \`specifics\` as a reading
object (the book title + numbered chapters) and mark that goal's main reading
template with detail = { "kind": "sequential" } so sessions walk the chapters in
order. Respond only by calling the propose_plan tool.`,
    tool: {
      name: "propose_plan",
      description: "Propose milestones and task templates for the goal.",
      input_schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          goalTitle: { type: "string" },
          successCriteria: { type: "string" },
          milestones: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              properties: {
                key: { type: "string" },
                title: { type: "string" },
                order: { type: "integer", minimum: 0 },
                completionCriteria: { type: "string" },
                targetDate: { type: ["string","null"] }
              },
              required: ["key","title","order","completionCriteria"]
            }
          },
          templates: { type: "array", items: proposedTemplateSchema },
          // The goal's concrete object (the specific book + chapters). Optional;
          // omit/null when the goal has no concrete series.
          specifics: goalSpecificsSchema
        },
        required: ["goalTitle","successCriteria","milestones","templates"]
      }
    },
    userContent: (p) =>
      `Goal spec: ${JSON.stringify(p.spec)}\n\nConstraints: ${JSON.stringify(p.profile)}`
  },

  replan: {
    system:
`You are a goals coach revising an existing plan based on how the user actually
did. Return a PlanDiff: a small set of operations against the current plan
(reduce frequency, shrink effort, swap to the minimum variant, reorder
milestones, push a date). Prefer the smallest change that helps. NEVER produce
datetimes — scheduling is handled separately. If the situation is ambiguous,
return zero operations and instead ask ONE clarifying question with 2–3 choices.
Be encouraging, never shaming. If prior validation violations are listed, fix
them. Respond only by calling the propose_diff tool.`,
    tool: {
      name: "propose_diff",
      description: "Propose a small diff of operations against the current plan, or a clarifying question.",
      input_schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          summary: { type: "string" },
          operations: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              properties: {
                kind: { type: "string", enum: [
                  "addTemplate","removeTemplate","modifyTemplate","swapToMinimumViable",
                  "pauseTemplate","resumeTemplate","addMilestone","reorderMilestones",
                  "shiftGoalTargetDate","shiftMilestoneTargetDate","completeMilestone"] },
                targetTemplateID: { type: ["string","null"] },
                targetMilestoneID: { type: ["string","null"] },
                newTemplate: { ...proposedTemplateSchema, type: ["object","null"] },
                newEffortMinutes: { type: ["integer","null"] },
                newTimesPerWeek: { type: ["integer","null"] },
                newWeekdays: { type: ["array","null"], items: { type: "string", enum: weekdayEnum } },
                newTitle: { type: ["string","null"] },
                newTargetDate: { type: ["string","null"] },
                orderedMilestoneIDs: { type: ["array","null"], items: { type: "string" } },
                note: { type: ["string","null"] }
              },
              required: ["kind"]
            }
          },
          clarifyingQuestion: { type: ["string","null"] },
          clarifyingChoices: { type: "array", items: { type: "string" } }
        },
        required: ["summary","operations","clarifyingChoices"]
      }
    },
    userContent: (p) =>
      `Current plan: ${JSON.stringify(p.plan)}\n\nPerformance: ${JSON.stringify(p.snapshot)}\n` +
      `Trigger: ${p.trigger}\nUser message: ${p.userMessage ?? "(none)"}\n` +
      `Prior validation violations to fix: ${JSON.stringify(p.priorViolations ?? [])}`
  },

  coach: {
    system:
`You are the user's ongoing goals coach. Be warm, direct and brief. If the user
asks to change their plan or is struggling, you MAY attach a proposed PlanDiff
(same rules as replanning: operations against the current plan, no datetimes, or
a single clarifying question). Otherwise just reply. Never give medical advice;
refer to professional resources on risk signals. Respond only by calling the
coach_reply tool.`,
    tool: {
      name: "coach_reply",
      description: "Reply to the user, optionally attaching a proposed plan diff.",
      input_schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          message: { type: "string" },
          proposedDiff: {
            type: ["object","null"],
            additionalProperties: false,
            properties: {
              summary: { type: "string" },
              operations: { type: "array", items: { type: "object" } },
              clarifyingQuestion: { type: ["string","null"] },
              clarifyingChoices: { type: "array", items: { type: "string" } }
            },
            required: ["summary","operations","clarifyingChoices"]
          }
        },
        required: ["message"]
      }
    },
    userContent: (p) =>
      `Plan: ${JSON.stringify(p.plan ?? null)}\nPerformance: ${JSON.stringify(p.snapshot ?? null)}\n` +
      `Conversation:\n${formatHistory(p.history)}\n\nUser: ${p.userMessage}`
  },

  review: {
    system:
`You are writing a short, warm weekly-review narrative (2–3 sentences) reflecting
on how the user's week went, grounded in the numbers. Encouraging and honest,
never shaming. Respond only by calling the write_review tool.`,
    tool: {
      name: "write_review",
      description: "Write the weekly review narrative.",
      input_schema: {
        type: "object",
        additionalProperties: false,
        properties: { narrative: { type: "string" } },
        required: ["narrative"]
      }
    },
    userContent: (p) =>
      `Plan: ${JSON.stringify(p.plan)}\nPerformance: ${JSON.stringify(p.snapshot)}`
  }
};

function formatHistory(history: { role: string; text: string }[] | undefined): string {
  if (!history?.length) return "(empty)";
  return history.map((m) => `${m.role}: ${m.text}`).join("\n");
}
