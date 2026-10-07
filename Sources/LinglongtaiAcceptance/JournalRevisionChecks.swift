import Foundation
import LinglongtaiShared

func runJournalRevisionChecks(check: (String, Bool) -> Void) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("island-journal-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let encoder = JSONEncoder()
        let events = (0..<300).map { AgentEvent(type: "upsert", id: UUID(), agent: "Codex", title: "fixture \($0)") }
        var data = Data()
        for event in events { data += try encoder.encode(event); data.append(10) }
        let fullSize = data.count
        data += Data("{\"type\":\"connection\"".utf8)
        try data.write(to: url)
        let first = try EventJournal.read(at: url, offset: 0)
        check("journal: batch is bounded to 256 complete rows", first.events.count == 256 && first.end < UInt64(fullSize))
        let second = try EventJournal.read(at: url, offset: first.end)
        check("journal: reads only the unread suffix without duplicating history", second.events.count == 44 && second.events.first?.id == events[256].id)
        check("journal: incomplete last row keeps its cursor", second.end == UInt64(fullSize))
        let pending = try EventJournal.read(at: url, offset: second.end)
        check("journal: partial write does not advance or fabricate an event", pending.start == pending.end && pending.events.isEmpty)
        let unchanged = try Data(contentsOf: url)
        check("journal: reader never truncates or rotates writer offsets", unchanged == data)
        let reset = try EventJournal.read(at: url, offset: UInt64(data.count + 1))
        check("journal: an externally replaced shorter log safely restarts at zero", reset.start == 0 && reset.events.count == 256)
        let capped = try EventJournal.read(at: url, offset: 0, byteLimit: 1)
        check("journal: byte cap never skips an incomplete row", capped.end == 0 && capped.events.isEmpty)
        let malformed = Data("not-json\n{\"type\":\"connection\"}\n".utf8)
        try malformed.write(to: url)
        let valid = try EventJournal.read(at: url, offset: 0)
        check("journal: malformed complete row is consumed without fabricating task", valid.end == UInt64(malformed.count) && valid.events.count == 1)
    } catch { check("journal fixtures complete: \(error)", false) }
}
