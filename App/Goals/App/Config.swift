import Foundation

/// App configuration sourced from the build settings / Info.plist. The LLM proxy
/// URL is injected via `Secrets.xcconfig` (see App/Goals/Resources/Secrets.example.xcconfig);
/// when absent, the app runs entirely on `MockLLMService` (docs/PLAN.md §3.3).
enum Config {
    /// Base URL of the LLM proxy, or nil to use the offline mock service.
    static var llmProxyBaseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "LLMProxyBaseURL") as? String,
              !raw.isEmpty,
              !raw.contains("$("), // unsubstituted xcconfig placeholder
              let url = URL(string: raw) else {
            return nil
        }
        return url
    }

    static var usingLiveBackend: Bool { llmProxyBaseURL != nil }

    /// Google OAuth iOS client ID, injected via `Secrets.xcconfig` (also read by
    /// the GoogleSignIn SDK from the `GIDClientID` plist key). Nil when not
    /// configured — the Google Calendar integration then shows "setup required".
    static var googleClientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !raw.isEmpty,
              !raw.contains("$(") else { // unsubstituted xcconfig placeholder
            return nil
        }
        return raw
    }

    static var googleSignInAvailable: Bool { googleClientID != nil }
}
