import Foundation

/// Confirmed execution intervals, not foreground/user attention time. Pairing
/// real callbacks avoids inventing an end time after a lost Stop. Open tails
/// are deliberately excluded; silence beyond the evidence limit is incomplete.
public struct AIWorkDuration: Sendable {
    private struct Active: Sendable {
        var session: String?
        var date: Date
    }
    public struct Summary: Equatable, Sendable {
        public var seconds: TimeInterval
        public var incomplete: Bool
        public var loading = false
        public init(seconds: TimeInterval, incomplete: Bool, loading: Bool = false) {
            self.seconds = seconds; self.incomplete = incomplete; self.loading = loading
        }
        public var label: String {
            // Display-only and built from numbers, so translated here rather than at render.
            if loading { return L("统计中") }
            let minutes = Int(max(0, seconds) / 60)
            if minutes == 0 { return L(seconds > 0 ? "不到 1 分钟" : "0 分钟") }
            return minutes < 60 ? LF("%lld 分钟", minutes) : LF("%lld 小时 %lld 分钟", minutes / 60, minutes % 60)
        }
    }
    private var active: [UUID: Active] = [:]
    private var intervals: [DateInterval] = []
    private var unknown: [Date] = []
    private var watermarks: [UUID: Date] = [:]
    private var terminal: Set<UUID> = []
    private var sessionsByTask: [UUID: String] = [:]
    public init() {}

    public mutating func consume(_ event: AgentEvent) {
        guard let date = event.createdAt, let agent = event.agent,
              IntegrationConfiguration.providers.contains(AgentKind.resolve(agent)), event.sourceEvent != nil else { return }
        if event.type == "source-unknown" { discontinuity(at: date); return }
        if event.type == "ambiguous-turn" {
            guard event.sessionID != nil else { unknown.append(date); return }
            for (id, value) in active where value.session == event.sessionID && date >= value.date {
                active.removeValue(forKey: id)
                watermarks[id] = date
            }
            unknown.append(date)
            return
        }
        if event.type == "end-session" {
            guard event.sessionID != nil else { return }
            for (id, value) in active where value.session == event.sessionID && date >= value.date {
                close(id, at: date, confirmed: true)
                terminal.insert(id); watermarks[id] = date
            }
            for (id, session) in sessionsByTask where session == event.sessionID && date >= (watermarks[id] ?? .distantPast) {
                terminal.insert(id); watermarks[id] = date
            }
            return
        }
        guard event.type == "upsert", let id = event.id, let status = event.status else { return }
        guard !terminal.contains(id), date >= (watermarks[id] ?? .distantPast) else { return }
        watermarks[id] = date
        if let session = event.sessionID { sessionsByTask[id] = session }
        if let old = event.replacesTaskID, let value = active.removeValue(forKey: old) { active[id] = value }
        // An interrupted round has no terminal timestamp. A new Claude prompt
        // retires it without counting the unobserved gap.
        if event.sourceEvent == "UserPromptSubmit" && AgentKind.resolve(agent) == .claude && event.sessionID != nil {
            for (old, value) in active where old != id && value.session == event.sessionID {
                active.removeValue(forKey: old)
                unknown.append(date)
            }
        }
        close(id, at: date, confirmed: true)
        if [.completed, .failed, .cancelled].contains(status) { terminal.insert(id) }
        if status == .running && event.requiresApproval != true {
            active[id] = Active(session: event.sessionID, date: date)
        }
    }

    public mutating func discardHistory(before date: Date) {
        intervals.removeAll { $0.end < date }
        unknown.removeAll { $0 < date }
    }
    public mutating func discontinuity(at date: Date) {
        active.removeAll()
        unknown.append(date)
    }

    private mutating func close(_ id: UUID, at date: Date, confirmed: Bool) {
        guard let value = active[id], date >= value.date else { return }
        active.removeValue(forKey: id)
        let gap = date.timeIntervalSince(value.date)
        if confirmed && gap <= AgentActivityMotion.unresolvedLimit {
            if gap > 0 { intervals.append(DateInterval(start: value.date, end: date)) }
        } else { unknown.append(date); unknown.append(value.date) }
    }

    public func summary(now: Date, calendar: Calendar = .autoupdatingCurrent) -> Summary {
        let start = calendar.startOfDay(for: now)
        let slices = intervals.compactMap { interval -> DateInterval? in
            let lower = max(start, interval.start), upper = min(now, interval.end)
            return upper > lower ? DateInterval(start: lower, end: upper) : nil
        }.sorted { $0.start < $1.start }
        var seconds: TimeInterval = 0
        var merged: DateInterval?
        for slice in slices {
            if let previous = merged {
                if slice.start <= previous.end { merged = DateInterval(start: previous.start, end: max(previous.end, slice.end)) }
                else { seconds += previous.duration; merged = slice }
            } else { merged = slice }
        }
        seconds += merged?.duration ?? 0
        let pending = active.values.contains { $0.date <= now }
        return Summary(seconds: seconds, incomplete: pending || unknown.contains { $0 >= start && $0 <= now })
    }
}
