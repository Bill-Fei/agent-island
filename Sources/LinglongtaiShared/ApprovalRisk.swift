import Foundation

/// Reminder-only detection of risky fragments in an approval's parameters.
/// It never blocks or auto-decides anything, and a miss is expected (it is a heuristic).
public enum ApprovalRisk {
    public struct Match: Equatable, Sendable {
        public var label: String
        public var range: Range<String.Index>
    }

    private static let rules: [(label: String, pattern: String)] = [
        ("递归删除", "(?i)\\brm\\s+(-[a-z]*[rf][a-z]*\\s+)+"),
        ("管理员权限", "(?i)\\b(sudo|doas)\\b"),
        ("强制推送", "(?i)\\bgit\\s+push\\b[^\\n;|&]*\\s(--force(-with-lease)?|-f)\\b"),
        ("丢弃本地改动", "(?i)\\bgit\\s+(reset\\s+--hard|clean\\s+-[a-z]*f|checkout\\s+--\\s)"),
        ("下载后直接执行", "(?i)\\b(curl|wget)\\b[^\\n]*\\|\\s*(sudo\\s+)?(ba|z)?sh\\b"),
        ("放开权限", "(?i)\\bchmod\\s+(-[a-z]+\\s+)*(777|a\\+rwx|-R)\\b"),
        ("磁盘级操作", "(?i)\\b(dd\\s+if=|mkfs(\\.\\w+)?\\b|diskutil\\s+(erase|partition))"),
        ("删除数据库表", "(?i)\\b(drop\\s+(table|database)|truncate\\s+table)\\b")
    ]

    public static func matches(in text: String) -> [Match] {
        var found: [Match] = []
        for rule in rules {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: rule.pattern, options: .regularExpression, range: searchRange) {
                found.append(Match(label: rule.label, range: range))
                guard range.upperBound < text.endIndex else { break }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Distinct labels across every field, in first-seen order.
    public static func labels(in fields: [ApprovalShortcut.Field]) -> [String] {
        var seen: [String] = []
        for field in fields where field.key != "working_directory" {
            for match in matches(in: field.value) where !seen.contains(match.label) { seen.append(match.label) }
        }
        return seen
    }
}
