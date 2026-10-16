import Foundation
import Darwin

/// Claude Code applies a PermissionRequest decision only after every matching
/// hook has returned. The Feishu bridge's hook holds each approval until the
/// phone answers, so an island decision alone stalled until the user answered
/// in the app. Whichever hook gets the user's answer first touches a per-session
/// marker; the other sees it and returns without a decision.
///
/// Contract shared with feishu-bridge/notify.mjs: directory
/// `~/Library/Application Support/LinglongtaiHUD/decided/`, file name = the
/// hook's `session_id` (only `[A-Za-z0-9_-]`, at most 128 characters), and its
/// mtime is the decision time. The file holds no content.
public enum SiblingDecision {
    static var directory: URL { LinglongtaiPaths.applicationSupport.appendingPathComponent("decided") }

    public static func key(_ session: String?) -> String? {
        guard let session, !session.isEmpty, session.count <= 128,
              session.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return session
    }

    public static func mark(_ key: String?) {
        guard let key else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(key).path
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }
        futimes(fd, nil)
        Darwin.close(fd)
    }

    /// True when another surface answered this session's prompt after `since`.
    public static func decided(_ key: String?, since: Date?) -> Bool {
        guard let key, let since else { return false }
        var info = stat()
        guard lstat(directory.appendingPathComponent(key).path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return false }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return modified > since
    }
}
