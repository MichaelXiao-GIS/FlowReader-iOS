import Foundation

/// An acknowledged action remains confirmed even if optional status details fail to refresh.
struct SignInViewState {
    private(set) var status: SignInStatus?
    private(set) var receipt: SignInReceipt?
    private(set) var actionError: String?
    private(set) var statusError: String?
    private var generation: UUID?
    private var serviceDay: String?

    var hasSigned: Bool { status?.signedToday == true || receipt != nil }
    var detailsNotice: String? {
        hasSigned && statusError != nil ? "今日签到已确认，连续天数等详情暂未更新。" : nil
    }
    var visibleError: String? { actionError ?? (hasSigned ? nil : statusError) }

    mutating func prepare(generation: UUID, serviceDay: String) {
        if self.generation != generation || self.serviceDay != serviceDay { self = Self() }
        self.generation = generation
        self.serviceDay = serviceDay
        actionError = nil
        statusError = nil
    }

    mutating func loaded(_ status: SignInStatus) { self.status = status; statusError = nil }
    mutating func failedStatus(_ error: Error) { statusError = error.localizedDescription }
    mutating func beginAction() { actionError = nil }
    mutating func confirmed(_ receipt: SignInReceipt) { self.receipt = receipt; actionError = nil; statusError = nil }
    mutating func restoreConfirmedDay() { receipt = SignInReceipt(alreadySigned: true, rewards: []); actionError = nil }
    mutating func failedAction(_ error: Error) { actionError = error.localizedDescription }
}
