import Foundation
import GoalsCore

/// Networking `LLMService` that talks to the thin proxy (docs/PLAN.md §3.2).
/// The proxy holds the provider key, pins server-side prompts by version, and
/// returns schema-constrained JSON. This client adds the *decode-repair*
/// round-trip from §3.3: if the structured result fails to decode, it asks the
/// proxy to repair once before surfacing an error.
///
/// When no proxy URL is configured the app uses `MockLLMService` instead (wired
/// in `AppContainer`), so the product is fully runnable with zero backend.
struct LLMClient: LLMService {

    let baseURL: URL
    let session: URLSession
    /// Supplies a device attestation / auth token for the proxy (App Attest in
    /// production; a stub in development).
    let tokenProvider: @Sendable () async -> String?

    init(baseURL: URL,
         session: URLSession = .shared,
         tokenProvider: @escaping @Sendable () async -> String? = { nil }) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: LLMService

    func onboardingTurn(state: OnboardingState, latestUserText: String,
                        unmetRequirements: [String]) async throws -> OnboardingTurnResult {
        struct Req: Encodable {
            let state: OnboardingState
            let latestUserText: String
            let unmetRequirements: [String]
        }
        struct Res: Decodable {
            let state: OnboardingState
            let assistantMessage: String
            let choices: [String]?
            let stage: OnboardingStage
        }
        let res: Res = try await call(task: "onboardingTurn", version: PromptVersion.onboarding,
                                      payload: Req(state: state, latestUserText: latestUserText,
                                                   unmetRequirements: unmetRequirements))
        return OnboardingTurnResult(state: res.state, assistantMessage: res.assistantMessage,
                                    choices: res.choices ?? [], stage: res.stage)
    }

    func generatePlan(spec: GoalSpec, profile: ConstraintProfile) async throws -> PlanProposal {
        struct Req: Encodable { let spec: GoalSpec; let profile: ConstraintProfile }
        return try await call(task: "generatePlan", version: PromptVersion.planGeneration,
                              payload: Req(spec: spec, profile: profile))
    }

    func replan(plan: Plan, snapshot: PerformanceSnapshot, trigger: RevisionTrigger,
                userMessage: String?, priorViolations: [String]) async throws -> PlanDiff {
        struct Req: Encodable {
            let plan: Plan; let snapshot: PerformanceSnapshot
            let trigger: String; let userMessage: String?; let priorViolations: [String]
        }
        return try await call(task: "replan", version: PromptVersion.replan,
                              payload: Req(plan: plan, snapshot: snapshot,
                                           trigger: trigger.rawValue, userMessage: userMessage,
                                           priorViolations: priorViolations))
    }

    func coachTurn(plan: Plan?, snapshot: PerformanceSnapshot?, history: [ChatMessage],
                   userMessage: String) async throws -> CoachReply {
        struct Req: Encodable {
            let plan: Plan?; let snapshot: PerformanceSnapshot?
            let history: [WireMessage]; let userMessage: String
        }
        struct Res: Decodable { let message: String; let proposedDiff: PlanDiff? }
        let res: Res = try await call(task: "coach", version: PromptVersion.coach,
                                      payload: Req(plan: plan, snapshot: snapshot,
                                                   history: history.map(WireMessage.init),
                                                   userMessage: userMessage))
        return CoachReply(message: res.message, proposedDiff: res.proposedDiff)
    }

    func reviewNarrative(snapshot: PerformanceSnapshot, plan: Plan) async throws -> String {
        struct Req: Encodable { let snapshot: PerformanceSnapshot; let plan: Plan }
        struct Res: Decodable { let narrative: String }
        let res: Res = try await call(task: "review", version: PromptVersion.review,
                                      payload: Req(snapshot: snapshot, plan: plan))
        return res.narrative
    }

    // MARK: - Transport

    /// A trimmed chat message shape for the wire (no SwiftData/UI concerns).
    private struct WireMessage: Encodable {
        let role: String
        let text: String
        init(_ m: ChatMessage) { role = m.role.rawValue; text = m.text }
    }

    private struct Envelope<P: Encodable>: Encodable {
        let task: String
        let promptVersion: String
        let schemaVersion: String
        let repair: Bool
        let payload: P
    }

    private func call<P: Encodable, R: Decodable>(task: String,
                                                  version: String,
                                                  payload: P) async throws -> R {
        do {
            return try await send(task: task, version: version, payload: payload, repair: false)
        } catch let error as DecodingError {
            // One repair round-trip: ask the proxy to re-emit valid JSON.
            _ = error
            return try await send(task: task, version: version, payload: payload, repair: true)
        }
    }

    private func send<P: Encodable, R: Decodable>(task: String, version: String,
                                                  payload: P, repair: Bool) async throws -> R {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/llm"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(PromptVersion.schema, forHTTPHeaderField: "X-Schema-Version")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let envelope = Envelope(task: task, promptVersion: version,
                                schemaVersion: PromptVersion.schema, repair: repair, payload: payload)
        request.httpBody = try JSON.encoder.encode(envelope)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.transport("Proxy returned \(http.statusCode)")
        }

        // The proxy wraps the structured result under "result".
        let wrapper = try JSON.decoder.decode(ResultWrapper<R>.self, from: data)
        return wrapper.result
    }
}

// Generic types can't be nested in a generic function, so this lives at file scope.
private struct ResultWrapper<T: Decodable>: Decodable { let result: T }
