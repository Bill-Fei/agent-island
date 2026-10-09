import Foundation
import LinglongtaiShared

func runAlphaSetupRevisionChecks(check: (String, Bool) -> Void) {
    let binary = URL(fileURLWithPath: "/tmp/alpha fixture/o'neil/linglongtaictl")
    for kind in IntegrationConfiguration.providers {
        do {
            let original = Data("{\"permissions\":{\"allow\":[\"unchanged\"]},\"hooks\":{\"Stop\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"other-observer\"}]}]}}".utf8)
            let merged = try IntegrationConfiguration.merge(original, binary: binary, provider: kind)
            check("alpha: \(kind) installs all observer events", IntegrationConfiguration.isInstalled(merged, binary: binary, provider: kind))
            let settings = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
            check("alpha: preserves unrelated permission settings", (settings["permissions"] as? [String: [String]])?["allow"] == ["unchanged"])
            check("alpha: preserves another observer", String(decoding: merged, as: UTF8.self).contains("other-observer"))
            let repeated = try IntegrationConfiguration.merge(merged, binary: binary, provider: kind)
            check("alpha: install is idempotent", repeated == merged)
            let removed = try IntegrationConfiguration.merge(merged, binary: binary, provider: kind, uninstall: true)
            check("alpha: uninstall removes only island observers", !IntegrationConfiguration.isInstalled(removed, binary: binary, provider: kind) && String(decoding: removed, as: UTF8.self).contains("other-observer"))
            check("alpha: no approval relay command", !String(decoding: merged, as: UTF8.self).contains("--approval-relay"))
        } catch { check("alpha: fixture configuration merge \(kind)", false) }
    }
    check("alpha: apostrophe path shell quoted", IntegrationConfiguration.shellQuote("a'b") == "'a'\\''b'")
    check("alpha: unsupported provider never appears installed", !IntegrationConfiguration.isInstalled(Data("{}".utf8), binary: binary, provider: .doubao))
    runFingerprintedBridgeUpgradeChecks(check: check)
    runClaudeRelayPreservationChecks(check: check)
    for text in ["[]", "{\"hooks\":[]}", "{\"hooks\":{\"Stop\":[{}]}}", "invalid"] {
        do {
            _ = try IntegrationConfiguration.merge(Data(text.utf8), binary: binary, provider: .codex)
            check("alpha: malformed config rejected", false)
        } catch { check("alpha: malformed config rejected", true) }
    }
}

/// Counts observer entries whose command points at any bridge in `home`.
private func observerEntries(_ data: Data, home: URL) -> Int {
    guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = settings["hooks"] as? [String: Any] else { return -1 }
    let events = IntegrationConfiguration.events(for: .codex)
    return events.reduce(0) { total, event in
        let groups = hooks[event] as? [[String: Any]] ?? []
        return total + groups.reduce(0) { count, group in
            let entries = group["hooks"] as? [[String: Any]] ?? []
            return count + entries.filter { entry in
                IntegrationConfiguration.isOwnedCommand(entry["command"] as? String ?? "", provider: .codex, home: home)
            }.count
        }
    }
}

/// Upgrading writes the bridge to a path named after the binary's digest, so a new
/// build never reuses the old path. These checks pin the two failures that caused:
/// an upgrade that doubles every observer, and an uninstall that removes none.
private func runFingerprintedBridgeUpgradeChecks(check: (String, Bool) -> Void) {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("island-upgrade-fixture-" + UUID().uuidString)
    let bins = home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/bin")
    let first = bins.appendingPathComponent("linglongtaictl-0123456789abcdef")
    let second = bins.appendingPathComponent("linglongtaictl-fedcba9876543210")
    let stale = bins.appendingPathComponent("linglongtaictl-cafebabe00ffeedd")
    let leftover = bins.appendingPathComponent("linglongtaictl-legacy-name")
    let outside = URL(fileURLWithPath: "/tmp/alpha fixture/o'neil/linglongtaictl-deadbeefdeadbeef")
    // Serialize the seed instead of writing it as a JSON literal: a shell-quoted
    // path contains `'\''`, and `\'` is not a legal JSON escape, so a hand-written
    // literal cannot carry these commands at all. Going through JSONSerialization
    // matches how the configuration is really written.
    func entry(_ command: String) -> [String: Any] { ["type": "command", "command": command, "timeout": 2] }
    let seed: [String: Any] = ["hooks": ["PreToolUse": [["hooks": [
        entry(IntegrationConfiguration.command(binary: first, provider: .codex)),
        entry(IntegrationConfiguration.command(binary: stale, provider: .codex)),
        entry(IntegrationConfiguration.command(binary: leftover, provider: .codex)),
        entry(IntegrationConfiguration.command(binary: outside, provider: .codex)),
        entry("other-observer"),
    ]]]]]
    guard let seeded = try? JSONSerialization.data(withJSONObject: seed) else {
        check("alpha: upgrade fixture serializes", false)
        return
    }
    guard let merged = try? IntegrationConfiguration.merge(seeded, binary: second, provider: .codex, previousBinary: first, home: home) else {
        check("alpha: upgrade fixture merges", false)
        return
    }
    let text = String(decoding: merged, as: UTF8.self)
    check("alpha: upgrade reclaims bridges from every earlier build", observerEntries(merged, home: home) == IntegrationConfiguration.events(for: .codex).count)
    check("alpha: upgrade drops the previous bridge command", !text.contains(first.lastPathComponent))
    check("alpha: upgrade drops an unreferenced older bridge command", !text.contains(stale.lastPathComponent))
    check("alpha: upgrade keeps a bridge name we do not own", text.contains(leftover.lastPathComponent))
    check("alpha: upgrade keeps a bridge from another directory", text.contains(outside.lastPathComponent))
    check("alpha: upgrade keeps a foreign observer", text.contains("other-observer"))
    let removed = (try? IntegrationConfiguration.merge(merged, binary: second, provider: .codex, uninstall: true, home: home)) ?? Data()
    check("alpha: uninstall removes island observers added by a newer bridge", observerEntries(removed, home: home) == 0 && String(decoding: removed, as: UTF8.self).contains("other-observer"))
    check("alpha: bridge-shaped but unrelated paths stay foreign", !IntegrationConfiguration.isOwnedCommand("/tmp/linglongtaictl-0123456789abcdef hook --provider codex", provider: .codex, home: home))
}

/// Setup must not silently revoke the Claude approval relay a user opted in to
/// with `install_hooks.py --approval-relay`, nor ever add one on its own.
private func runClaudeRelayPreservationChecks(check: (String, Bool) -> Void) {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("island-relay-fixture-" + UUID().uuidString)
    let bins = home.appendingPathComponent("Library/Application Support/LinglongtaiHUD/bin")
    let first = bins.appendingPathComponent("linglongtaictl-0123456789abcdef")
    let second = bins.appendingPathComponent("linglongtaictl-fedcba9876543210")
    let relay = IntegrationConfiguration.command(binary: first, provider: .claude) + " --approval-relay"
    let seed: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": relay, "timeout": 50]]]]]]
    guard let seeded = try? JSONSerialization.data(withJSONObject: seed),
          let merged = try? IntegrationConfiguration.merge(seeded, binary: second, provider: .claude, home: home),
          let removed = try? IntegrationConfiguration.merge(merged, binary: second, provider: .claude, uninstall: true, home: home),
          let codex = try? IntegrationConfiguration.merge(seeded, binary: second, provider: .codex, home: home) else {
        check("alpha: relay fixture merges", false)
        return
    }
    let text = String(decoding: merged, as: UTF8.self)
    let newRelay = IntegrationConfiguration.command(binary: second, provider: .claude) + " --approval-relay"
    check("alpha: reinstall keeps an existing Claude relay opt-in on the new bridge", text.contains(newRelay))
    check("alpha: reinstall drops the old relay bridge", !text.contains(first.lastPathComponent))
    check("alpha: preserved relay still counts as installed", IntegrationConfiguration.isInstalled(merged, binary: second, provider: .claude))
    check("alpha: uninstall removes the relay too", !String(decoding: removed, as: UTF8.self).contains("--approval-relay"))
    check("alpha: a Claude relay never leaks into another provider",
          !String(decoding: codex, as: UTF8.self).contains("hook --provider codex --approval-relay"))
}
