import Foundation

struct ReadingTimeContext: Equatable, Hashable, Sendable {
    let generation: UUID
    let bookID: Int
    let chapterID: Int

    var isOnlineNovel: Bool { bookID > 0 && chapterID > 0 }
}

struct ReadingTimeSlice: Identifiable, Equatable, Sendable {
    let id: UUID
    let generation: UUID
    let bookID: Int
    let chapterID: Int
    let seconds: Int
    let readingDate: String
}

/// Accounts only for intervals explicitly marked as visible foreground reading.
/// The owner supplies a monotonic clock and must pass nil while inactive, loading or covered.
/// No running timestamp or pending duration survives process termination.
struct ReadingTimeLedger: Sendable {
    private struct Sample: Sendable {
        let now: TimeInterval
        let wallDate: Date
    }
    private struct Key: Hashable, Sendable {
        let context: ReadingTimeContext
        let readingDate: String
    }
    private struct Bucket: Sendable {
        var duration: TimeInterval
        let sequence: UInt64
    }

    private let minimumBatchSeconds: Int
    private let idleTimeout: TimeInterval
    private var generation: UUID?
    private var context: ReadingTimeContext?
    private var anchor: Sample?
    private var lastInteraction: TimeInterval?
    private var lastObservedTime: TimeInterval?
    private var buckets: [Key: Bucket] = [:]
    private var sequence: UInt64 = 0

    init(minimumBatchSeconds: Int = 60, idleTimeout: TimeInterval = 120) {
        self.minimumBatchSeconds = max(1, minimumBatchSeconds)
        // The Android reader stops at two minutes without activity; do not extend this ceiling.
        self.idleTimeout = idleTimeout.isFinite && idleTimeout > 0 ? min(120, idleTimeout) : 120
    }

    var pendingSeconds: Int {
        buckets.values.reduce(0) { $0 + Int($1.duration.rounded(.down)) }
    }

    /// Includes subsecond remainders, which remain attached to their chapter and service day.
    var pendingDuration: TimeInterval { buckets.values.reduce(0) { $0 + $1.duration } }

    var isCounting: Bool {
        guard context != nil, let now = lastObservedTime, let interaction = lastInteraction else { return false }
        return now < interaction + idleTimeout
    }

    /// nil settles and pauses the current interval. Repeated updates do not count twice or
    /// refresh the activity deadline. A different generation discards all old-account time.
    mutating func setContext(_ next: ReadingTimeContext?, now: TimeInterval, wallDate: Date) {
        guard Self.isValid(now: now, wallDate: wallDate) else { pauseWithoutAccruing(); return }
        if let next, generation != next.generation {
            reset()
            generation = next.generation
        } else { sample(now: now, wallDate: wallDate) }
        let wasPaused = context == nil
        guard let next, next.isOnlineNovel else { pauseWithoutAccruing(); return }
        context = next
        anchor = Sample(now: now, wallDate: wallDate)
        lastObservedTime = now
        if wasPaused || lastInteraction == nil { lastInteraction = now }
    }

    /// A heartbeat settles elapsed time; it never manufactures one second per timer callback.
    mutating func sample(now: TimeInterval, wallDate: Date) {
        guard Self.isValid(now: now, wallDate: wallDate) else { pauseWithoutAccruing(); return }
        guard let context, let anchor, let interaction = lastInteraction else {
            lastObservedTime = now
            return
        }
        guard now >= anchor.now else {
            // A clock reset is not a negative interval and must not create a new idle grace.
            pauseWithoutAccruing()
            return
        }
        let end = min(now, interaction + idleTimeout)
        if end > anchor.now {
            // Wall-clock changes never enlarge elapsed time. The previous sample's date anchors
            // the measured monotonic interval; the new wall date anchors only subsequent samples.
            accrue(duration: end - anchor.now, startingAt: anchor.wallDate, context: context)
        }
        self.anchor = Sample(now: now, wallDate: wallDate)
        lastObservedTime = now
    }

    /// Settle only through the old idle deadline, then resume from this actual interaction.
    mutating func markInteraction(now: TimeInterval, wallDate: Date) {
        guard Self.isValid(now: now, wallDate: wallDate) else { pauseWithoutAccruing(); return }
        sample(now: now, wallDate: wallDate)
        lastInteraction = now
        lastObservedTime = now
        if context != nil { anchor = Sample(now: now, wallDate: wallDate) }
    }

    /// Call sample/setContext before taking. Integer increments are removed before dispatch;
    /// the reporter must never replay them after a timeout or other ambiguous response.
    /// The 60-second default is this client's batching policy, not an asserted server threshold.
    mutating func takePending(force: Bool = false) -> [ReadingTimeSlice] {
        guard force || pendingSeconds >= minimumBatchSeconds else { return [] }
        var result: [ReadingTimeSlice] = []
        for (key, bucket) in buckets.sorted(by: { $0.value.sequence < $1.value.sequence }) {
            let seconds = Int(bucket.duration.rounded(.down))
            guard seconds > 0 else { continue }
            result.append(ReadingTimeSlice(id: UUID(), generation: key.context.generation,
                bookID: key.context.bookID, chapterID: key.context.chapterID,
                seconds: seconds, readingDate: key.readingDate))
            let remainder = bucket.duration - Double(seconds)
            if remainder == 0 { buckets[key] = nil }
            else { buckets[key]?.duration = remainder }
        }
        return result
    }

    /// Logout, identity replacement or explicit session invalidation must call this immediately.
    mutating func reset() {
        generation = nil
        buckets = [:]
        sequence = 0
        pauseWithoutAccruing()
    }

    private mutating func pauseWithoutAccruing() {
        context = nil
        anchor = nil
        lastInteraction = nil
        lastObservedTime = nil
    }

    private mutating func accrue(duration: TimeInterval, startingAt date: Date, context: ReadingTimeContext) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        var cursor = date
        var remaining = duration
        // An accrued interval is bounded by idleTimeout (at most 120 seconds), so at most
        // two ordinary service days are involved, even if a timer callback arrives very late.
        while remaining > 0 {
            guard let day = calendar.dateInterval(of: .day, for: cursor) else { return }
            let untilMidnight = day.end.timeIntervalSince(cursor)
            guard untilMidnight > 0 else { return }
            let amount = min(remaining, untilMidnight)
            let key = Key(context: context, readingDate: ReadingTimeProtocol.serviceDate(for: cursor))
            if buckets[key] != nil { buckets[key]?.duration += amount }
            else {
                buckets[key] = Bucket(duration: amount, sequence: sequence)
                sequence &+= 1
            }
            remaining -= amount
            cursor = day.end
        }
    }

    private static func isValid(now: TimeInterval, wallDate: Date) -> Bool {
        now.isFinite && now >= 0 && wallDate.timeIntervalSinceReferenceDate.isFinite
    }
}
