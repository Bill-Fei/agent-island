import Foundation

/// Pure key mapping and parameter layout for the approval review popover (no UI, no I/O).
public enum ApprovalShortcut {
    public enum Action: Equatable, Sendable { case allowOnce, deny, close }

    private static let returnKeys: Set<UInt16> = [36, 76]
    private static let deleteKey: UInt16 = 51
    private static let escapeKey: UInt16 = 53

    /// Allow/deny require exactly ⌘; Esc closes without a decision. Auto-repeat never fires.
    public static func action(keyCode: UInt16, command: Bool, option: Bool, control: Bool,
                              shift: Bool, isRepeat: Bool) -> Action? {
        guard !isRepeat else { return nil }
        if keyCode == escapeKey { return command || option || control || shift ? nil : .close }
        guard command, !option, !control, !shift else { return nil }
        if returnKeys.contains(keyCode) { return .allowOnce }
        if keyCode == deleteKey { return .deny }
        return nil
    }

    public struct Field: Equatable, Identifiable, Sendable {
        public var key: String
        public var value: String
        public var id: String { key }
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    private static let priorityKeys = ["command", "cmd", "file_path", "path", "url", "pattern", "query", "description"]

    /// Every argument is returned; common high-signal keys are only moved to the front.
    /// Returns nil when the context is not the expected JSON shape, so callers show the raw text.
    public static func fields(fromContext context: String) -> [Field]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any],
              let arguments = object["arguments"] as? [String: Any] else { return nil }
        var result: [Field] = []
        if let directory = object["working_directory"] as? String, !directory.isEmpty {
            result.append(Field(key: "working_directory", value: directory))
        }
        let ordered = arguments.keys.sorted { lhs, rhs in
            let l = priorityKeys.firstIndex(of: lhs) ?? Int.max
            let r = priorityKeys.firstIndex(of: rhs) ?? Int.max
            return l == r ? lhs < rhs : l < r
        }
        let arg = ordered.map { Field(key: $0, value: render(arguments[$0])) }
        // Command/path-like arguments lead; the working directory follows them.
        let leading = arg.filter { priorityKeys.contains($0.key) }
        let rest = arg.filter { !priorityKeys.contains($0.key) }
        return leading + result + rest
    }

    private static func render(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let string = value as? String { return string }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }
}
