import Foundation

/// Claude Code stores explicit conversation names as separate `custom-title`
/// rows in its JSONL files. Only those rows are decoded; message/tool rows are
/// skipped as bytes and never used to invent a title. This is not Claude Chat.
public struct ClaudeConversationTitles: Sendable {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    private struct Entry: Sendable {
        let size: Int
        let modifiedAt: Date
        let inode: UInt64
        let offset: UInt64
        let title: String?
    }
    private var entries: [URL: Entry] = [:]

    public init() {}

    /// Initial reads stream in 64 KiB blocks. Subsequent reads inspect only
    /// appended bytes, retaining no transcript. Missing sources return nil.
    public mutating func snapshot(root: URL = defaultRoot) -> [String: String]? {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return nil }
        var files: [(URL, Date)] = []
        for project in projects {
            guard let flags = try? project.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  flags.isDirectory == true, flags.isSymbolicLink != true else { continue }
            guard let children = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { return nil }
            // Direct children only: nested sub-agent transcripts aren't chats.
            for file in children where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                files.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        let selected = files.prefix(4096).map(\.0)
        entries = entries.filter { selected.contains($0.key) }
        var titles: [String: String] = [:]
        for file in selected {
            let rawID = file.deletingPathExtension().lastPathComponent
            guard ConversationTitles.clean(rawID) != nil, rawID.utf8.count <= 256 else { continue }
            if let attributes = try? fm.attributesOfItem(atPath: file.path),
               let size = (attributes[.size] as? NSNumber)?.intValue,
               let modifiedAt = attributes[.modificationDate] as? Date,
               let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value {
                let previous = entries[file]
                if previous?.size != size || previous?.modifiedAt != modifiedAt || previous?.inode != inode {
                    let appending = previous?.inode == inode && size > (previous?.size ?? Int.max)
                    let start = appending ? previous!.offset : 0
                    if let read = Self.read(file, rawID: rawID, from: start, size: UInt64(size), title: appending ? previous?.title : nil) {
                        entries[file] = Entry(size: size, modifiedAt: modifiedAt, inode: inode, offset: read.offset, title: read.title)
                    }
                }
            }
            if let title = entries[file]?.title {
                let key = ConversationTitles.sessionKey(provider: .claude, rawID: rawID)
                // Newest project copy wins for resumed/relocated sessions.
                if titles[key] == nil { titles[key] = title }
            }
        }
        return titles
    }

    private static func read(_ file: URL, rawID: String, from start: UInt64, size: UInt64,
                             title initial: String?) -> (offset: UInt64, title: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            var position = start, committed = start
            var row = Data(), overflow = false
            var title = initial
            while position < size {
                guard let bytes = try handle.read(upToCount: Int(min(64 * 1024, size - position))), !bytes.isEmpty else { break }
                for byte in bytes {
                    position += 1
                    if byte == 0x0A {
                        if !overflow,
                           // Inspect only the row header before JSON decoding.
                           String(decoding: row.prefix(128), as: UTF8.self).range(of: #"^\s*\{\s*"type"\s*:\s*"custom-title"\s*[,}]"#, options: .regularExpression) != nil,
                           let object = try? JSONSerialization.jsonObject(with: row) as? [String: Any],
                           object["type"] as? String == "custom-title", object["sessionId"] as? String == rawID {
                            // An explicitly cleared name removes the old name.
                            title = ConversationTitles.clean(object["customTitle"] as? String)
                        }
                        row.removeAll(keepingCapacity: true)
                        overflow = false
                        committed = position
                    } else if row.count < 8192, !overflow { row.append(byte) }
                    else { overflow = true; row.removeAll(keepingCapacity: true) }
                }
            }
            // Retry a partial last row from its start on the next size change.
            return (committed, title)
        } catch { return nil }
    }
}
