import Foundation

/// Stored credentials and verified logins are different states.
struct AccountConnectionSnapshot: Sendable {
    let generation: UUID
    let usesAppAccount: Bool
    var appAccount: AccountProfile?
    var webAccount: AccountProfile?
    var appError: String?
    var webError: String?
    var appNeedsLogin = false
    var webNeedsLogin = false

    var primaryAccount: AccountProfile? { usesAppAccount ? appAccount : webAccount }
    var primaryError: String? { usesAppAccount ? appError : webError }
    var hasSavedConnection: Bool { usesAppAccount || webAccount != nil || webNeedsLogin || webError != nil }
}

extension SFAPI {
    /// A secondary website login cannot take priority over the App account's library.
    func libraryProfile() async throws -> AccountProfile {
        if hasSavedAppLogin() { return try await accountServiceProfile() }
        return try await webProfile()
    }

    func accountConnections() async throws -> AccountConnectionSnapshot {
        let generation = sessionGeneration()
        let app = hasSavedAppLogin(), web = hasSavedWebLogin()
        var result = AccountConnectionSnapshot(generation: generation, usesAppAccount: app)
        if app {
            do {
                guard hasAppSession() else { throw SFAPIError.authenticationRequired("账号登录已过期，请重新登录菠萝包。") }
                result.appAccount = try await accountServiceProfile()
            }
            catch {
                if AccountShelfState.isCancellation(error) { throw error }
                result.appError = error.localizedDescription
                result.appNeedsLogin = Self.isAuthenticationFailure(error)
            }
        }
        if web {
            do {
                guard hasWebSession() else { throw SFAPIError.authenticationRequired("网页阅读授权已过期，可在需要时重新授权。") }
                result.webAccount = try await webProfile()
            }
            catch {
                if AccountShelfState.isCancellation(error) { throw error }
                result.webError = error.localizedDescription
                result.webNeedsLogin = Self.isAuthenticationFailure(error)
            }
        }
        try Task.checkCancellation()
        guard sessionGeneration() == generation else { throw CancellationError() }
        return result
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        switch error {
        case SFAPIError.loginRequired, SFAPIError.authenticationRequired: return true
        default: return false
        }
    }
}
