import AppKit
import Combine
import Foundation
import Darwin
import LinglongtaiShared

@MainActor
final class AlphaIntegrationSetup: ObservableObject {
    @Published var selected: Set<AgentKind> = []
    @Published private(set) var installed: Set<AgentKind> = []
    @Published private(set) var message = "尚未安装。请选择要接入的 Agent。"
    @Published private(set) var busy = false
    @Published private(set) var diagnostics: [AgentKind: String] = [:]
    private var timer: Timer?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var helper: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/linglongtaictl")
        return (try? IntegrationConfiguration.helperURL(home: home, bundled: bundled))
            ?? home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/bin/linglongtaictl")
    }

    init() {
        let setup = self
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in setup.refresh() }
        }
    }

    func refresh() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/linglongtaictl")
        let matches = (try? Data(contentsOf: helper)) == (try? Data(contentsOf: bundled))
            && FileManager.default.isExecutableFile(atPath: helper.path)
        for kind in IntegrationConfiguration.providers {
            guard let path = IntegrationConfiguration.relativePath(for: kind) else { continue }
            let url = home.appendingPathComponent(path)
            do {
                try Self.checkPath(url)
                let data = FileManager.default.fileExists(atPath: url.path) ? try Self.read(url) : nil
                diagnostics[kind] = IntegrationConfiguration.health(data, binary: helper, provider: kind, home: home, bridgeMatches: matches)
                if let health = HookHealth.read(provider: kind, directory: LinglongtaiPaths.applicationSupport), !health.parsed,
                   Date().timeIntervalSince(health.receivedAt) < 86400 {
                    diagnostics[kind] = "收到未识别回调 · 可能是协议变更或非支持事件"
                }
            } catch { diagnostics[kind] = "配置无法安全读取 · 请检查权限或路径" }
        }
        installed = Set(IntegrationConfiguration.providers.filter { kind in
            guard let path = IntegrationConfiguration.relativePath(for: kind),
                  let data = try? Self.read(home.appendingPathComponent(path)) else { return false }
            return IntegrationConfiguration.isInstalled(data, binary: helper, provider: kind)
                && FileManager.default.isExecutableFile(atPath: helper.path)
        })
    }

    func confirm(uninstall: Bool) {
        guard !busy, !selected.isEmpty else { return }
        let providers = IntegrationConfiguration.providers.filter { selected.contains($0) }
        let alert = NSAlert()
        alert.messageText = uninstall ? L("移除所选接入？") : L("安装所选状态观察器？")
        alert.informativeText = providers.compactMap { IntegrationConfiguration.relativePath(for: $0) }.map { "~/" + $0 }.joined(separator: "\n")
            + "\n\n" + L("以上配置先备份再合并。接入使用固定桥接入口；后续灵动岛升级会原子更新桥接，保留旧版用于回退，已运行的回调不中断。保留其他设置和已有审批选择，不新增信任或审批权限，不启动任务。卸载不删除历史。安装前请暂时关闭会编辑这些配置的原应用。")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: uninstall ? L("备份并移除") : L("备份并安装"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        let home = home, helper = helper
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/linglongtaictl")
        Task {
            let result = await Task.detached(priority: .utility) {
                do {
                    try Self.apply(providers, uninstall: uninstall, home: home, helper: helper, bundled: bundled)
                    return uninstall ? "已移除所选观察器，历史保留。" : "已安装，尚未证明连接成功。请用真实任务验证；Codex 在 /hooks 审阅信任。"
                } catch { return LF("未完成：%@ 请重新检查；不会自动重试。", L(error.localizedDescription)) }
            }.value
            message = result
            busy = false
            refresh()
        }
    }

    nonisolated private static func checkPath(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw NSError(domain: "IslandSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "路径包含符号链接；原配置未修改，请使用手动接入。"])
            }
            current.deleteLastPathComponent()
        }
    }

    nonisolated static func read(_ url: URL) throws -> Data {
        try checkPath(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 4_194_304 else {
            throw IntegrationConfiguration.ConfigurationError.invalidConfiguration
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func write(_ data: Data, to url: URL, mode: Int, expecting original: Data? = nil, compare: Bool = false) throws {
        try checkPath(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".island-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        if compare {
            let current = FileManager.default.fileExists(atPath: url.path) ? try read(url) : nil
            guard current == original else {
                throw NSError(domain: "IslandSetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "配置在写入前发生变化，已停止覆盖；请重新检查。"])
            }
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Explicit roots make installation testable without touching personal data.
    nonisolated static func apply(_ providers: [AgentKind], uninstall: Bool, home: URL, helper: URL, bundled: URL) throws {
        let fm = FileManager.default, stamp = UUID().uuidString
        let lockURL = home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/.alpha-setup.lock")
        try checkPath(lockURL)
        try fm.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFD = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD) }
            throw NSError(domain: "IslandSetup", code: 4, userInfo: [NSLocalizedDescriptionKey: "另一个接入操作正在进行，请稍后重试。"])
        }
        defer { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        var plans: [(url: URL, original: Data?, updated: Data)] = []
        for kind in providers {
            guard let path = IntegrationConfiguration.relativePath(for: kind) else { continue }
            let url = home.appendingPathComponent(path)
            try checkPath(url)
            let original = fm.fileExists(atPath: url.path) ? try read(url) : nil
            if uninstall && original == nil { continue }
            let legacy = home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/bin/linglongtaictl")
            let previous = fm.fileExists(atPath: legacy.path) ? legacy : (fm.fileExists(atPath: helper.path) ? helper : nil)
            // `home` lets merge recognize bridges left by *any* earlier build by
            // structure, so an upgrade cannot strand a stale observer behind.
            let updated = try IntegrationConfiguration.merge(original, binary: helper, provider: kind, uninstall: uninstall, previousBinary: previous, home: home)
            if original != updated { plans.append((url, original, updated)) }
        }
        if !uninstall {
            guard fm.isExecutableFile(atPath: bundled.path) else {
                throw NSError(domain: "IslandSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少桥接程序，请使用完整 .app；无需 Python。"])
            }
            try checkPath(helper)
            try replaceBridge(helper: helper, bundled: bundled)
        }
        var changed: [(url: URL, original: Data?, updated: Data)] = []
        do {
            for plan in plans {
                let current = fm.fileExists(atPath: plan.url.path) ? try read(plan.url) : nil
                guard current == plan.original else {
                    throw NSError(domain: "IslandSetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "原应用同时更新配置，已停止合并。请重新检查。"])
                }
                if let original = plan.original {
                    try write(original, to: plan.url.appendingPathExtension("linglongtai-backup-" + stamp), mode: 0o600)
                }
                try write(plan.updated, to: plan.url, mode: 0o600, expecting: plan.original, compare: true)
                changed.append(plan)
            }
        } catch {
            for plan in changed.reversed() {
                guard (try? read(plan.url)) == plan.updated else { continue }
                if let original = plan.original { try? write(original, to: plan.url, mode: 0o600) }
                else {
                    // Recoverable rollback of a newly created configuration.
                    try? fm.moveItem(at: plan.url, to: plan.url.appendingPathExtension("island-incomplete-" + stamp))
                }
            }
            throw error
        }
    }

    nonisolated private static func replaceBridge(helper: URL, bundled: URL) throws {
        try checkPath(bundled)
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            throw NSError(domain: "IslandSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少可执行桥接程序"])
        }
        let data = try Data(contentsOf: bundled)
        try checkPath(helper)
        if FileManager.default.fileExists(atPath: helper.path) {
            let previous = try Data(contentsOf: helper)
            if previous == data && FileManager.default.isExecutableFile(atPath: helper.path) { return }
            try write(previous, to: helper.appendingPathExtension("previous"), mode: 0o700)
        }
        try write(data, to: helper, mode: 0o700)
    }

    /// Migrates only existing owned commands; never adds/re-enables a provider.
    /// Atomic file replacement leaves already-running hook processes intact.
    nonisolated static func upgradeExisting(home: URL, bundled: URL) throws {
        let fm = FileManager.default
        let lockURL = home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/.alpha-setup.lock")
        try checkPath(lockURL)
        try fm.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(fd, LOCK_UN) }
        let helper = try IntegrationConfiguration.helperURL(home: home, bundled: bundled)
        var plans: [(url: URL, original: Data, updated: Data)] = []
        var bridges: Set<URL> = []
        for provider in IntegrationConfiguration.providers {
            guard let path = IntegrationConfiguration.relativePath(for: provider) else { continue }
            let url = home.appendingPathComponent(path)
            try checkPath(url)
            guard fm.fileExists(atPath: url.path) else { continue }
            let original = try read(url)
            let owned = IntegrationConfiguration.configuredBridges(original, provider: provider, home: home)
            bridges.formUnion(owned)
            let updated = try IntegrationConfiguration.migrateOwned(original, binary: helper, provider: provider, home: home)
            if updated != original { plans.append((url, original, updated)) }
        }
        guard !bridges.isEmpty else { return }
        let aliasesURL = helper.deletingLastPathComponent().appendingPathComponent("legacy-bridges.json")
        var aliases: Set<String> = []
        if fm.fileExists(atPath: aliasesURL.path) {
            aliases = Set(try JSONDecoder().decode([String].self, from: read(aliasesURL)))
        }
        // Store names, never arbitrary paths. Continue maintaining cached old
        // commands on later upgrades without restoring any removed Hook entry.
        aliases.formUnion(bridges.filter { $0.path != helper.path }.map(\.lastPathComponent))
        for name in aliases {
            let url = helper.deletingLastPathComponent().appendingPathComponent(name)
            guard url.deletingLastPathComponent().path == helper.deletingLastPathComponent().path,
                  name != "linglongtaictl",
                  IntegrationConfiguration.isOwnedCommand(IntegrationConfiguration.command(binary: url, provider: .claude), provider: .claude, home: home) else {
                throw IntegrationConfiguration.ConfigurationError.invalidConfiguration
            }
        }
        try write(JSONEncoder().encode(aliases.sorted()), to: aliasesURL, mode: 0o600)
        try replaceBridge(helper: helper, bundled: bundled)
        // Providers may cache the old command for the current session. Refresh
        // only legacy paths actually referenced in their settings, not all bins.
        for name in aliases {
            try replaceBridge(helper: helper.deletingLastPathComponent().appendingPathComponent(name), bundled: bundled)
        }
        let stamp = UUID().uuidString
        for plan in plans {
            guard try read(plan.url) == plan.original else {
                throw NSError(domain: "IslandSetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "配置同时发生变化，已停止迁移；请重新检查。"])
            }
            try write(plan.original, to: plan.url.appendingPathExtension("linglongtai-backup-" + stamp), mode: 0o600)
            try write(plan.updated, to: plan.url, mode: 0o600, expecting: plan.original, compare: true)
        }
    }
}
