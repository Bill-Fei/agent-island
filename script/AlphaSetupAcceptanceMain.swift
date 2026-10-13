import Foundation
import LinglongtaiShared

@main
struct AlphaSetupAcceptance {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/island-alpha-setup-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("support/bin/linglongtaictl")
        let bundled = root.appendingPathComponent("bundled-helper")
        try Data("fixture-only-not-a-real-agent".utf8).write(to: bundled)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundled.path)
        let config = root.appendingPathComponent(".codex/hooks.json")
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"trust\":\"untouched\",\"hooks\":{}}".utf8)
        try original.write(to: config)
        try AlphaIntegrationSetup.apply([.codex], uninstall: false, home: root, helper: helper, bundled: bundled)
        let installed = try Data(contentsOf: config)
        precondition(IntegrationConfiguration.isInstalled(installed, binary: helper, provider: .codex))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
        let configAttributes = try fm.attributesOfItem(atPath: config.path)
        let helperAttributes = try fm.attributesOfItem(atPath: helper.path)
        precondition((configAttributes[.posixPermissions] as! Int) == 0o600)
        precondition((helperAttributes[.posixPermissions] as! Int) == 0o700)
        let backups = try fm.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("linglongtai-backup") }
        let backupData = try Data(contentsOf: backups[0])
        precondition(backups.count == 1 && backupData == original)
        try AlphaIntegrationSetup.apply([.codex], uninstall: false, home: root, helper: helper, bundled: bundled)
        let repeatedInstalled = try Data(contentsOf: config)
        precondition(repeatedInstalled == installed)
        // Real upgrade fixtures: retain relay choice, refresh cached legacy
        // paths, preserve foreign settings, and never add removed providers.
        let stable = try IntegrationConfiguration.helperURL(home: root, bundled: bundled)
        let legacy = stable.deletingLastPathComponent().appendingPathComponent("linglongtaictl-0123456789abcdef")
        try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old bridge".utf8).write(to: legacy)
        let claude = root.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seeded: [String: Any] = ["permissions": ["untouched": true], "hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": IntegrationConfiguration.command(binary: legacy, provider: .claude) + " --approval-relay", "timeout": 50]]]]]]
        try JSONSerialization.data(withJSONObject: seeded).write(to: claude)
        try AlphaIntegrationSetup.upgradeExisting(home: root, bundled: bundled)
        let migrated = try Data(contentsOf: claude)
        precondition(String(decoding: migrated, as: UTF8.self).contains(IntegrationConfiguration.command(binary: stable, provider: .claude) + " --approval-relay"))
        precondition(IntegrationConfiguration.configuredBridges(migrated, provider: .claude, home: root).allSatisfy { $0 == stable })
        let legacyData = try Data(contentsOf: legacy), bundleData = try Data(contentsOf: bundled)
        precondition(legacyData == bundleData)
        let preservedConfig = try Data(contentsOf: config)
        precondition(preservedConfig == repeatedInstalled)
        precondition(!fm.fileExists(atPath: root.appendingPathComponent(".workbuddy/settings.json").path))
        try AlphaIntegrationSetup.upgradeExisting(home: root, bundled: bundled)
        let repeatedMigration = try Data(contentsOf: claude)
        precondition(repeatedMigration == migrated)
        let secondBuild = Data("fixture-v2".utf8)
        try secondBuild.write(to: bundled)
        try AlphaIntegrationSetup.upgradeExisting(home: root, bundled: bundled)
        let secondLegacy = try Data(contentsOf: legacy)
        precondition(secondLegacy == secondBuild)
        let secondConfig = try Data(contentsOf: claude)
        precondition(secondConfig == migrated)
        try fm.removeItem(at: claude)
        try AlphaIntegrationSetup.apply([.codex, .claude], uninstall: true, home: root, helper: helper, bundled: bundled)
        let removed = try Data(contentsOf: config)
        precondition(!IntegrationConfiguration.isInstalled(removed, binary: helper, provider: .codex))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
        let linkedRoot = root.appendingPathComponent("linked")
        try fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedRoot.appendingPathComponent(".codex"), withDestinationURL: config.deletingLastPathComponent())
        do {
            try AlphaIntegrationSetup.apply([.codex], uninstall: false, home: linkedRoot, helper: helper, bundled: bundled)
            fatalError("symlink must be rejected")
        } catch { }
        print("Native Alpha setup fixture checks passed: selected-only, backup, private permissions, idempotence, uninstall and symlink rejection. No personal configurations changed.")
    }
}
