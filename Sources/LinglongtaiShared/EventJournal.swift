import Foundation

/// Bounded incremental reads. Never rotates/truncates the shared append log:
/// the hook writer's crash-recovery cursor refers to absolute byte offsets.
public enum EventJournal {
    public struct Batch: Sendable {
        public let start: UInt64
        public let end: UInt64
        public let events: [AgentEvent]
        public let blockedByOversizedLine: Bool
    }

    public static func read(at url: URL, offset: UInt64, byteLimit: Int = 1_048_576,
                            lineLimit: Int = 256) throws -> Batch {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = offset <= size ? offset : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: max(1, byteLimit)) ?? Data()
        var end = data.startIndex
        var count = 0
        for index in data.indices where data[index] == 10 {
            end = data.index(after: index)
            count += 1
            if count >= max(1, lineLimit) { break }
        }
        // Keep incomplete lines unread. Malformed complete rows consume their
        // cursor but cannot fabricate tasks. An oversized unterminated row is
        // intentionally not skipped; diagnostics must report this blockage.
        let complete = data[..<end]
        let decoder = JSONDecoder()
        let events = complete.split(separator: 10).compactMap {
            try? decoder.decode(AgentEvent.self, from: Data($0))
        }
        return Batch(start: start, end: start + UInt64(complete.count), events: events,
                     blockedByOversizedLine: complete.isEmpty && data.count >= max(1, byteLimit))
    }
}
