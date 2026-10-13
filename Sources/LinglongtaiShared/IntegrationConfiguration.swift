import Foundation

/// Allowlisted observer configuration. Never changes provider trust or replies
/// to permission requests. Shared by native setup and isolated fixture checks.
public enum IntegrationConfiguration {
    public static let providers: [AgentKind] = [.codex, .claude, .workBuddy]
    public static func relativePath(for provider: AgentKind) -> String? {
        switch provider {
        case .codex: return ".codex/hooks.json"
        case .claude: return ".claude/settings.json"
        case .workBuddy: return ".workbuddy/settings.json"
        default: return nil
        }
    }
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func command(binary: URL, provider: AgentKind) -> String {
        shellQuote(binary.path) + " hook --provider " + provider.rawValue
    }
    public static func helperURL(home: URL, bundled: URL) throws -> URL {
        home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/bin/linglongtaictl")
    }

    /// Upgrade only entries the user already installed. Missing events remain
    /// missing: launching the app must never re-enable a removed integration.
    public static func migrateOwned(_ original: Data, binary: URL, provider: AgentKind, home: URL) throws -> Data {
        guard original.count <= 4_194_304,
              var settings = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw ConfigurationError.invalidConfiguration
        }
        guard let existing = settings["hooks"] else { return original }
        guard var hooks = existing as? [String: Any] else { throw ConfigurationError.invalidConfiguration }
        var changed = false
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { throw ConfigurationError.invalidConfiguration }
            for index in groups.indices {
                guard var entries = groups[index]["hooks"] as? [[String: Any]] else { throw ConfigurationError.invalidConfiguration }
                for entry in entries.indices {
                    let old = entries[entry]["command"] as? String ?? ""
                    guard isOwnedCommand(old, provider: provider, home: home) else { continue }
                    let new = command(binary: binary, provider: provider) + (old.hasSuffix(" --approval-relay") ? " --approval-relay" : "")
                    if new != old { entries[entry]["command"] = new; changed = true }
                }
                groups[index]["hooks"] = entries
            }
            hooks[event] = groups
        }
        guard changed else { return original }
        settings["hooks"] = hooks
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }

    public static func configuredBridges(_ data: Data, provider: AgentKind, home: URL) -> [URL] {
        guard data.count <= 4_194_304,
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { value -> [URL] in
            (value as? [[String: Any]] ?? []).flatMap { group -> [URL] in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap { entry in
                    let value = entry["command"] as? String ?? ""
                    guard isOwnedCommand(value, provider: provider, home: home),
                          let range = value.range(of: " hook --provider ", options: .backwards) else { return nil }
                    return URL(fileURLWithPath: unquote(String(value[..<range.lowerBound])))
                }
            }
        }
    }

    public static func health(_ data: Data?, binary: URL, provider: AgentKind, home: URL,
                              bridgeMatches: Bool) -> String {
        guard let data else { return "尚未接入" }
        guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "配置无法读取" }
        if settings["disableAllHooks"] as? Bool == true { return "原应用已禁用 Hook" }
        let bridges = configuredBridges(data, provider: provider, home: home)
        guard !bridges.isEmpty else { return "尚未接入" }
        if bridges.contains(where: { $0.path != binary.path }) { return "旧版桥接 · 待迁移" }
        guard bridgeMatches else { return "桥接缺失或版本不匹配" }
        return isInstalled(data, binary: binary, provider: provider) ? "配置就绪 · 不代表任务运行中" : "配置不完整 · 请检查接入"
    }
    public static func events(for provider: AgentKind) -> [String] {
        let common = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
        switch provider {
        case .codex: return common + ["Interrupt"]
        case .claude: return common + ["Notification", "StopFailure", "PostToolUseFailure"]
        case .workBuddy: return common + ["Notification"]
        default: return []
        }
    }
    public static func ownedCommands(binary: URL, provider: AgentKind) -> Set<String> {
        let suffix = " hook --provider " + provider.rawValue
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        let pythonQuoted = binary.path.unicodeScalars.allSatisfy { safe.contains($0) }
            ? binary.path : shellQuote(binary.path)
        let commands = [command(binary: binary, provider: provider), pythonQuoted + suffix]
        return Set(commands + commands.map { $0 + " --approval-relay" })
    }

    /// Recognize our own hook entry by structure instead of by exact bridge path.
    ///
    /// The bridge is named `linglongtaictl-<sha256 prefix>`, so every build that
    /// changes the binary writes to a *new* path. Matching only the current and
    /// one remembered path therefore leaves earlier bridges behind on upgrade
    /// and uninstall, which duplicates every observer event. Mirrors the Python
    /// installer's `owned_command`: only the argument shape, provider, directory
    /// and file name are matched, never a substring of an unrelated command.
    public static func isOwnedCommand(_ value: String, provider: AgentKind, home: URL) -> Bool {
        guard providers.contains(provider) else { return false }
        let marker = " hook --provider "
        guard let range = value.range(of: marker, options: .backwards) else { return false }
        let quotedPath = String(value[value.startIndex..<range.lowerBound])
        let arguments = value[range.upperBound...].split(separator: " ").map(String.init)
        guard arguments.first == provider.rawValue else { return false }
        guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--approval-relay") else { return false }
        let path = unquote(quotedPath)
        guard !path.isEmpty else { return false }
        let binary = URL(fileURLWithPath: path).standardizedFileURL
        let expected = home
            .appendingPathComponent("Library/Application Support/LinglongtaiHUD/bin")
            .standardizedFileURL
        // Compare paths, not URLs: `deletingLastPathComponent()` marks the result as
        // a directory (trailing slash) and `appendingPathComponent` does not, so URL
        // equality is always false for these two spellings of the same directory.
        guard binary.deletingLastPathComponent().path == expected.path else { return false }
        let name = binary.lastPathComponent
        let suffix = name.hasPrefix("linglongtaictl-") ? String(name.dropFirst("linglongtaictl-".count)) : ""
        if name == "linglongtaictl" { return true }
        guard suffix.count == 16 else { return false }
        return suffix.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// Undo the escaping used by `shellQuote`, without running a shell.
    /// A quoted path is a leading `'`, a body with `'` written as `'\''`, and a
    /// trailing `'`; an unquoted path is returned unchanged.
    private static func unquote(_ value: String) -> String {
        let escaped = "'\\''"
        guard value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 else {
            return value.replacingOccurrences(of: escaped, with: "'")
        }
        let body = value.dropFirst().dropLast()
        return body.replacingOccurrences(of: escaped, with: "'")
    }
    public enum ConfigurationError: LocalizedError {
        case unsupportedProvider, invalidConfiguration
        public var errorDescription: String? {
            "配置无法安全合并或超过读取上限；原文件未修改。"
        }
    }
    public static func merge(_ original: Data?, binary: URL, provider: AgentKind, uninstall: Bool = false, previousBinary: URL? = nil, home: URL? = nil) throws -> Data {
        guard providers.contains(provider) else { throw ConfigurationError.unsupportedProvider }
        guard (original?.count ?? 0) <= 4_194_304 else { throw ConfigurationError.invalidConfiguration }
        var settings: [String: Any]
        if let original {
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw ConfigurationError.invalidConfiguration
            }
            settings = object
        } else { settings = [:] }
        var hooks: [String: Any] = [:]
        if let existing = settings["hooks"] {
            guard let object = existing as? [String: Any] else { throw ConfigurationError.invalidConfiguration }
            hooks = object
        }
        // `home` scopes structural recognition to this user's bridge directory so a
        // bridge left by any earlier build is reclaimed; the explicit path sets stay
        // as a fallback for callers that cannot supply one.
        let base = home ?? FileManager.default.homeDirectoryForCurrentUser
        var owned = ownedCommands(binary: binary, provider: provider)
        if let previousBinary { owned.formUnion(ownedCommands(binary: previousBinary, provider: provider)) }
        // Setup never opts in to the Claude approval relay, but it must not
        // silently revoke an opt-in made with `install_hooks.py --approval-relay`.
        let keepsRelay = provider == .claude && !uninstall
            && ((hooks["PermissionRequest"] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains { entry in
                    let command = entry["command"] as? String ?? ""
                    return command.hasSuffix(" --approval-relay")
                        && (owned.contains(command) || isOwnedCommand(command, provider: provider, home: base))
                }
            }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { throw ConfigurationError.invalidConfiguration }
            var remaining: [[String: Any]] = []
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else { throw ConfigurationError.invalidConfiguration }
                let kept = entries.filter { entry in
                    let command = entry["command"] as? String ?? ""
                    return !owned.contains(command) && !isOwnedCommand(command, provider: provider, home: base)
                }
                if !kept.isEmpty { group["hooks"] = kept; remaining.append(group) }
            }
            if remaining.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = remaining }
        }
        if !uninstall {
            for event in events(for: provider) {
                var groups = hooks[event] as? [[String: Any]] ?? []
                var group: [String: Any] = ["hooks": [["type": "command", "command": command(binary: binary, provider: provider), "timeout": 2]]]
                if keepsRelay && event == "PermissionRequest" {
                    group["hooks"] = [["type": "command", "command": command(binary: binary, provider: provider) + " --approval-relay", "timeout": 50]]
                }
                if event == "Notification" { group["matcher"] = "permission_prompt|elicitation_dialog|agent_needs_input" }
                groups.append(group)
                hooks[event] = groups
            }
        }
        settings["hooks"] = hooks
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        return data
    }
    public static func isInstalled(_ data: Data, binary: URL, provider: AgentKind) -> Bool {
        guard providers.contains(provider), data.count <= 4_194_304,
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        let owned = ownedCommands(binary: binary, provider: provider)
        return events(for: provider).allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { entry in
                    let command = entry["command"] as? String ?? ""
                    guard entry["type"] as? String == "command", owned.contains(command) else { return false }
                    let isRelay = command.hasSuffix(" --approval-relay")
                    if isRelay {
                        guard provider == .claude, event == "PermissionRequest", entry["timeout"] as? Int == 50 else { return false }
                    } else if entry["timeout"] as? Int != 2 { return false }
                    if event == "Notification" {
                        return group["matcher"] as? String == "permission_prompt|elicitation_dialog|agent_needs_input"
                    }
                    return true
                }
            }
        }
    }
}
