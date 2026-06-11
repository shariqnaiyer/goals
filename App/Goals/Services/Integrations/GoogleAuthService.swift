import Foundation
import UIKit
import GoogleSignIn

/// The only file that touches the GoogleSignIn SDK. Its types aren't Sendable,
/// so they stay confined to this @MainActor class; everything outward is plain
/// Strings/Dates. The SDK reads `GIDClientID` from Info.plist and keeps
/// refresh tokens in the Keychain — we never store tokens ourselves.
@MainActor
final class GoogleAuthService {

    enum Scope {
        static let calendarRead = "https://www.googleapis.com/auth/calendar.readonly"
        /// Granular scope: full control over calendars *the app created* (the
        /// "Goals" calendar) and nothing else. If some account type rejects it,
        /// the documented fallback is "https://www.googleapis.com/auth/calendar".
        static let calendarAppCreated = "https://www.googleapis.com/auth/calendar.app.created"
    }

    enum AuthError: LocalizedError {
        case notConfigured
        case noPresenter
        case notSignedIn
        case scopeDeclined

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google sign-in isn't configured in this build."
            case .noPresenter: return "Couldn't find a screen to present sign-in from."
            case .notSignedIn: return "Not signed in to Google."
            case .scopeDeclined: return "Calendar access wasn't granted."
            }
        }
    }

    var isSignedIn: Bool { GIDSignIn.sharedInstance.currentUser != nil }

    var accountEmail: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }

    /// Restore a previous session from the Keychain (app launch). Quietly
    /// returns false when there is none.
    func restorePreviousSignIn() async -> Bool {
        guard Config.googleSignInAvailable, GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            return false
        }
        do {
            _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            return true
        } catch {
            return false
        }
    }

    /// Interactive sign-in requesting calendar read access. Returns the
    /// account email for display.
    func signIn() async throws -> String {
        guard Config.googleSignInAvailable else { throw AuthError.notConfigured }
        guard let presenter = Self.presentingViewController() else { throw AuthError.noPresenter }
        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [Scope.calendarRead])
        } catch let error as GIDSignInError where error.code == .canceled {
            // The user closed the sheet — callers treat this as a quiet no-op.
            throw CancellationError()
        }
        guard result.user.grantedScopes?.contains(Scope.calendarRead) == true else {
            throw AuthError.scopeDeclined
        }
        return result.user.profile?.email ?? "Google account"
    }

    /// Incremental authorization: request additional scopes only when the
    /// feature needing them is enabled (e.g. export).
    func ensureScopes(_ scopes: [String]) async throws {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw AuthError.notSignedIn }
        let granted = Set(user.grantedScopes ?? [])
        let missing = scopes.filter { !granted.contains($0) }
        guard !missing.isEmpty else { return }
        guard let presenter = Self.presentingViewController() else { throw AuthError.noPresenter }
        let result = try await user.addScopes(missing, presenting: presenter)
        let nowGranted = Set(result.user.grantedScopes ?? [])
        guard missing.allSatisfy(nowGranted.contains) else { throw AuthError.scopeDeclined }
    }

    func hasScope(_ scope: String) -> Bool {
        GIDSignIn.sharedInstance.currentUser?.grantedScopes?.contains(scope) == true
    }

    /// A fresh access token, refreshing via the SDK if expired.
    func freshAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw AuthError.notSignedIn }
        let refreshed = try await user.refreshTokensIfNeeded()
        return refreshed.accessToken.tokenString
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    /// Sign out and revoke the app's grants with Google.
    func disconnect() async {
        try? await GIDSignIn.sharedInstance.disconnect()
    }

    /// Topmost view controller of the key window, for presenting the sign-in
    /// sheet from SwiftUI (which has no presenter of its own).
    private static func presentingViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
