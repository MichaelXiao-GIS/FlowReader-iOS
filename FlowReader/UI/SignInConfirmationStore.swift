import Foundation
import CryptoKit
import Observation

/// Stores only a hashed verified App account ID and the service day of a confirmed sign-in.
@MainActor @Observable
final class SignInConfirmationStore {
    static let shared = SignInConfirmationStore()
    static let storageKey = "signIn.confirmedServiceDays.v1"
    @ObservationIgnored private let defaults: UserDefaults
    private var confirmedDays: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        confirmedDays = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func isConfirmed(for account: AccountProfile, at date: Date = Date()) -> Bool {
        guard let key = Self.accountKey(account) else { return false }
        return confirmedDays[key] == SignInProtocol.serviceDay(at: date)
    }

    func record(_ receipt: SignInReceipt, for account: AccountProfile, at date: Date = Date()) {
        saveConfirmation(for: account, at: date)
    }

    func record(_ status: SignInStatus, for account: AccountProfile, at date: Date = Date()) {
        guard status.signedToday == true else { return }
        saveConfirmation(for: account, at: date)
    }

    private func saveConfirmation(for account: AccountProfile, at date: Date) {
        guard let key = Self.accountKey(account) else { return }
        let day = SignInProtocol.serviceDay(at: date)
        confirmedDays = confirmedDays.filter { $0.value == day }
        confirmedDays[key] = day
        defaults.set(confirmedDays, forKey: Self.storageKey)
    }

    private static func accountKey(_ account: AccountProfile) -> String? {
        // App profiles are verified with a positive account ID; a web-only/unknown ID is insufficient.
        guard account.id > 0 else { return nil }
        return SHA256.hash(data: Data("sfacg-app-account:\(account.id)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
