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
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var helper: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/linglongtaictl")
        return (try? IntegrationConfiguration.helperURL(home: home, bundled: bundled))
            ?? home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/bin/linglongtaictl")
    }

    func refresh() {
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
        alert.messageText = uninstall ? "移除所选接入？" : "安装所选状态观察器？"
        alert.informativeText = providers.compactMap { IntegrationConfiguration.relativePath(for: $0) }.map { "~/" + $0 }.joined(separator: "\n")
            + "\n\n以上配置先备份再合并。会为本次构建写入独立的桥接文件，不替换其他 Agent 正在使用的旧桥。保留其他设置，不修改信任或审批策略，不启动任务。卸载不删除历史。安装前请暂时关闭会编辑这些配置的原应用。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: uninstall ? "备份并移除" : "备份并安装")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        let home = home, helper = helper
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/linglongtaictl")
        Task {
            let result = await Task.detached(priority: .utility) {
                do {
                    try Self.apply(providers, uninstall: uninstall, home: home, helper: helper, bundled: bundled)
                    return uninstall ? "已移除所选观察器，历史保留。" : "已安装，尚未证明连接成功。请用真实任务验证；Codex 在 /hooks 审阅信任。"
                } catch { return "未完成：\(error.localizedDescription) 请重新检查；不会自动重试。" }
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

    nonisolated private static func read(_ url: URL) throws -> Data {
        try checkPath(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 4_194_304 else {
            throw IntegrationConfiguration.ConfigurationError.invalidConfiguration
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func write(_ data: Data, to url: URL, mode: Int) throws {
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
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
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
            if !fm.fileExists(atPath: helper.path) { try write(Data(contentsOf: bundled), to: helper, mode: 0o700) }
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
                try write(plan.updated, to: plan.url, mode: 0o600)
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
}
