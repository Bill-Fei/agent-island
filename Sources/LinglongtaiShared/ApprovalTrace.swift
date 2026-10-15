import Foundation
import Darwin

/// Metadata-only timeline of each relay request: request ID, stage and time.
/// Never records tool names, arguments, conversation text or stdout. It exists
/// to tell "decision never delivered" apart from "delivered but not accepted".
public enum ApprovalTrace {
    private static let maxBytes: off_t = 262_144
    static var url: URL { LinglongtaiPaths.applicationSupport.appendingPathComponent("approval-trace.jsonl") }

    public static func record(_ id: UUID, _ stage: String, heartbeatAge: TimeInterval? = nil) {
        var entry: [String: Any] = [
            "request": id.uuidString, "stage": stage,
            "at": Date().timeIntervalSince1970, "pid": Int(getpid()),
        ]
        if let heartbeatAge { entry["heartbeatAge"] = (heartbeatAge * 1000).rounded() / 1000 }
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        // O_NONBLOCK: a planted FIFO must never stall the hook or the HUD main thread.
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        // Rotate under the lock, only if this fd is still the live file.
        var live = stat()
        if info.st_size > maxBytes, lstat(url.path, &live) == 0,
           live.st_ino == info.st_ino, live.st_dev == info.st_dev {
            _ = rename(url.path, url.path + ".previous")
        }
        // Single small O_APPEND write: concurrent CLI and HUD lines never interleave.
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
