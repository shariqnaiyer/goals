// Server-side prompts and JSON schemas, pinned by version (docs/PLAN.md §3.2,
// §3.3). Keeping these on the proxy means prompt fixes ship without an app
// release. Each task forces structured output via a single-tool tool_choice so
// the model must return schema-valid JSON.

export type Task = "interview" | "generatePlan" | "replan" | "coach" | "review";

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
    minimumViableVariant: { type: ["string","null"] }
  },
  required: ["title","effortMinutes","cadence","weekdays","timesPerWeek","intervalDays","flexibility"]
};

export const SPECS: Record<Task, TaskSpec> = {
  interview: {
    system:
`You are an exceptionally warm, perceptive goals coach onboarding a new user.
Turn their vague aspiration into a well-formed goal with as FEW questions as
possible (ask at most 2–3 across the whole conversation). Resolve, in priority
order: outcome vs habit, deadline vs open-ended, current level, weekly time
budget. Be friendly and concise. When you have enough, set isComplete=true and
stop asking. Never give medical or clinical advice; if you detect crisis or
self-harm signals, gently suggest professional resources. Always respond by
calling the record_interview tool.`,
    tool: {
      name: "record_interview",
      description: "Record the structured goal spec and the next assistant message.",
      input_schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          spec: {
            type: "object",
            additionalProperties: false,
            properties: {
              title: { type: "string" },
              motivationStatement: { type: "string" },
              type: { type: "string", enum: ["outcome","habit"] },
              successCriteria: { type: "string" },
              targetDate: { type: ["string","null"], description: "yyyy-MM-dd or null" },
              currentLevel: { type: "string" },
              weeklyBudgetMinutes: { type: "integer", minimum: 0, maximum: 10080 },
              isComplete: { type: "boolean" },
              nextQuestion: { type: ["string","null"] }
            },
            required: ["title","motivationStatement","type","successCriteria",
                       "currentLevel","weeklyBudgetMinutes","isComplete"]
          },
          assistantMessage: { type: "string" }
        },
        required: ["spec","assistantMessage"]
      }
    },
    userContent: (p) =>
      `Conversation so far:\n${formatHistory(p.history)}\n\nCurrent draft spec: ${JSON.stringify(p.draft ?? null)}`
  },

  generatePlan: {
    system:
`You are a goals coach decomposing a confirmed goal into a realistic plan.
Produce 2–4 milestones and a small set of recurring task templates whose total
weekly load fits the user's weekly budget. Prefer 2–4 tasks. Give the main task
a gentle minimumViableVariant for bad days. Honour the user's constraints.
Respond only by calling the propose_plan tool.`,
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
          templates: { type: "array", items: proposedTemplateSchema }
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
