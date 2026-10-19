import Foundation

/// Decides which queued downloads may start. Pure and synchronous: the coordinator calls it on the
/// main actor and registers the started jobs before returning, so two calls can never over-commit.
public enum QueueScheduler {
    public struct Candidate: Sendable, Equatable {
        public var id: UUID
        public var state: DownloadState
        public var startMode: StartMode
        public var queuePosition: Int
        public var scheduledAt: Date?
        public var trashed: Bool

        public init(id: UUID, state: DownloadState, startMode: StartMode, queuePosition: Int, scheduledAt: Date?, trashed: Bool) {
            self.id = id
            self.state = state
            self.startMode = startMode
            self.queuePosition = queuePosition
            self.scheduledAt = scheduledAt
            self.trashed = trashed
        }
    }

    public static func selectToStart(candidates: [Candidate], activeCount: Int, maxConcurrent: Int,
                                     queueRunning: Bool, now: Date) -> [UUID] {
        let slots = max(0, maxConcurrent - activeCount)
        guard slots > 0 else { return [] }
        let eligible = candidates.filter { c in
            guard c.state == .queued, !c.trashed else { return false }
            if let at = c.scheduledAt {
                return at <= now                       // a per-download start time acts like "Start Now" once reached
            }
            return c.startMode == .immediate || queueRunning
        }
        // Explicitly started downloads first, then queue order.
        let ordered = eligible.sorted {
            let a = $0.startMode == .immediate || $0.scheduledAt != nil
            let b = $1.startMode == .immediate || $1.scheduledAt != nil
            if a != b { return a }
            return $0.queuePosition < $1.queuePosition
        }
        return Array(ordered.prefix(slots).map(\.id))
    }

    /// Moves `id` by `offset` positions among `orderedIDs` and returns the new order.
    public static func move(_ id: UUID, by offset: Int, in orderedIDs: [UUID]) -> [UUID] {
        guard let index = orderedIDs.firstIndex(of: id) else { return orderedIDs }
        var ids = orderedIDs
        let target = min(max(0, index + offset), ids.count - 1)
        ids.remove(at: index)
        ids.insert(id, at: target)
        return ids
    }
}

/// Evaluates the weekly queue schedule. Timers do not fire while the Mac sleeps, so the coordinator
/// calls this periodically and after wake with the last evaluation time; boundaries crossed in
/// between are detected here. Nothing runs while the app is not running.
public enum ScheduleEvaluator {
    public enum Action: Equatable, Sendable { case start, stop, none }

    public static func action(schedule: QueueSchedule, previousCheck: Date, now: Date, calendar: Calendar = .current) -> Action {
        guard schedule.enabled, now > previousCheck else { return .none }
        let lastStart = lastBoundary(minute: schedule.startMinute, weekdays: schedule.weekdays, after: previousCheck, upTo: now, calendar: calendar)
        let lastStop = schedule.stopEnabled
            ? lastBoundary(minute: schedule.stopMinute, weekdays: Set(1...7), after: previousCheck, upTo: now, calendar: calendar)
            : nil
        switch (lastStart, lastStop) {
        case (nil, nil): return .none
        case (.some, nil): return .start
        case (nil, .some): return .stop
        case (.some(let s), .some(let e)): return s > e ? .start : .stop
        }
    }

    /// Latest time-of-day boundary in (after, upTo] on an allowed weekday. Looks back at most 8 days.
    static func lastBoundary(minute: Int, weekdays: Set<Int>, after: Date, upTo: Date, calendar: Calendar) -> Date? {
        let startDay = calendar.startOfDay(for: max(after, upTo.addingTimeInterval(-8 * 86400)))
        var day = calendar.startOfDay(for: upTo)
        while day >= startDay {
            if let boundary = calendar.date(byAdding: .minute, value: minute, to: day),
               boundary > after, boundary <= upTo,
               weekdays.contains(calendar.component(.weekday, from: day)) {
                return boundary
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return nil
    }

    /// Next scheduled start, for display in Settings.
    public static func nextStart(schedule: QueueSchedule, after now: Date, calendar: Calendar = .current) -> Date? {
        guard schedule.enabled, !schedule.weekdays.isEmpty else { return nil }
        var day = calendar.startOfDay(for: now)
        for _ in 0..<8 {
            if let boundary = calendar.date(byAdding: .minute, value: schedule.startMinute, to: day), boundary > now,
               schedule.weekdays.contains(calendar.component(.weekday, from: day)) {
                return boundary
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}
