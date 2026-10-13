import Foundation

/// Bounded status only: never copy payload fields, provider output or secrets.
public struct HookHealth: Codable, Sendable {
    public let receivedAt: Date
    public let parsed: Bool
    public static func url(provider: AgentKind, directory: URL) -> URL {
        directory.appendingPathComponent("hook-health-" + provider.rawValue + ".json")
    }
    public static func record(provider: AgentKind, parsed: Bool, directory: URL, now: Date = Date()) {
        guard IntegrationConfiguration.providers.contains(provider) else { return }
        let url = url(provider: provider, directory: directory)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let data = try? JSONEncoder().encode(HookHealth(receivedAt: now, parsed: parsed)) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read(provider: AgentKind, directory: URL) -> HookHealth? {
        let url = url(provider: provider, directory: directory)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]))?.isSymbolicLink != true,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) <= 4096,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
