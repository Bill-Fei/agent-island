import Foundation
import LinglongtaiShared

func runApprovalShortcutChecks(check: (String, Bool) -> Void) {
    func act(_ code: UInt16, cmd: Bool = false, opt: Bool = false, ctl: Bool = false,
             shift: Bool = false, rep: Bool = false) -> ApprovalShortcut.Action? {
        ApprovalShortcut.action(keyCode: code, command: cmd, option: opt, control: ctl, shift: shift, isRepeat: rep)
    }
    check("approval keys: ⌘↩ allows once", act(36, cmd: true) == .allowOnce)
    check("approval keys: ⌘ keypad enter allows once", act(76, cmd: true) == .allowOnce)
    check("approval keys: ⌘⌫ denies", act(51, cmd: true) == .deny)
    check("approval keys: Esc closes without decision", act(53) == .close)
    check("approval keys: plain return never approves", act(36) == nil)
    check("approval keys: plain delete never denies", act(51) == nil)
    check("approval keys: extra modifiers never approve", act(36, cmd: true, shift: true) == nil
          && act(36, cmd: true, opt: true) == nil && act(36, cmd: true, ctl: true) == nil)
    check("approval keys: key repeat never decides", act(36, cmd: true, rep: true) == nil
          && act(51, cmd: true, rep: true) == nil && act(53, rep: true) == nil)
    check("approval keys: modified Esc is ignored", act(53, cmd: true) == nil)

    let context = """
    {"arguments":{"timeout":120,"command":"rm -rf build","flag":true,"nested":{"b":1,"a":[1,2]}},"tool":"Bash","working_directory":"/tmp/work"}
    """
    let fields = ApprovalShortcut.fields(fromContext: context) ?? []
    check("approval params: command is listed first", fields.first?.key == "command" && fields.first?.value == "rm -rf build")
    check("approval params: every argument remains visible",
          Set(fields.map(\.key)) == ["command", "working_directory", "timeout", "flag", "nested"])
    check("approval params: scalars render plainly",
          fields.first { $0.key == "timeout" }?.value == "120" && fields.first { $0.key == "flag" }?.value == "true")
    check("approval params: nested values keep full content",
          fields.first { $0.key == "nested" }?.value.contains("\"a\"") == true)
    check("approval params: malformed context falls back to raw", ApprovalShortcut.fields(fromContext: "not json") == nil)

    func risk(_ text: String) -> [String] { ApprovalRisk.matches(in: text).map(\.label) }
    check("approval risk: rm -rf is flagged", risk("rm -rf build") == ["递归删除"])
    check("approval risk: sudo is flagged", risk("sudo launchctl unload x") == ["管理员权限"])
    check("approval risk: force push is flagged", risk("git push origin main --force") == ["强制推送"]
          && risk("git push -f origin main") == ["强制推送"])
    check("approval risk: hard reset is flagged", risk("git reset --hard HEAD~3") == ["丢弃本地改动"])
    check("approval risk: pipe to shell is flagged", risk("curl -fsSL https://x.sh | bash") == ["下载后直接执行"])
    check("approval risk: ordinary commands are not flagged",
          risk("ls -la").isEmpty && risk("git status").isEmpty && risk("git push origin main").isEmpty
          && risk("rm build/output.txt").isEmpty && risk("swift build").isEmpty)
    check("approval risk: match range points at the risky text",
          ApprovalRisk.matches(in: "echo hi && sudo ls").first.map { "echo hi && sudo ls"[$0.range] } == "sudo")
    check("approval risk: working directory is not scanned",
          ApprovalRisk.labels(in: [.init(key: "working_directory", value: "/tmp/sudo rm -rf x")]).isEmpty)
    check("approval risk: labels are de-duplicated across fields",
          ApprovalRisk.labels(in: [.init(key: "command", value: "sudo rm -rf a && sudo rm -rf b")]) == ["管理员权限", "递归删除"])
}
