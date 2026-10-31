import Foundation

/// Keeps the last readable shelf visible while a newer request is pending or fails.
struct AccountShelfState {
    private(set) var books: [Book] = []
    private(set) var loading = false
    private(set) var hasSnapshot = false
    private(set) var notice: String?
    private(set) var error: String?
    private(set) var isComplete = false
    private var requestID: UUID?

    var isConfirmedEmpty: Bool { hasSnapshot && isComplete && books.isEmpty && error == nil && !loading }

    mutating func begin(_ request: UUID) {
        requestID = request
        loading = true
        error = nil
    }

    mutating func complete(_ result: BookshelfSyncResult, for request: UUID) {
        guard requestID == request else { return }
        if result.isComplete {
            books = result.books
        } else {
            // Unavailable sections must not make previously loaded books disappear.
            let refreshedIDs = Set(result.books.map(\.id))
            books = result.books + books.filter { !refreshedIDs.contains($0.id) }
        }
        hasSnapshot = true
        isComplete = result.isComplete
        notice = result.notice
        error = nil
        loading = false
        requestID = nil
    }

    mutating func fail(_ failure: Error, for request: UUID, taskIsCancelled: Bool = false) {
        guard requestID == request else { return }
        loading = false
        requestID = nil
        if taskIsCancelled || Self.isCancellation(failure) { return }
        error = failure.localizedDescription
    }

    mutating func reset() { self = Self() }

    static func isCancellation(_ failure: Error) -> Bool {
        if failure is CancellationError { return true }
        let error = failure as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isCancellation(underlying) }
        return false
    }
}
