#if canImport(Darwin)
public import Darwin
#else
public import Glibc
#endif
internal import Foundation

#if !canImport(Darwin)
/// Layout-compatible twin of Glibc's `struct ucred` (hidden behind
/// _GNU_SOURCE, which the Swift overlay does not define).
private struct LinuxUcred {
    var pid: pid_t = 0
    var uid: uid_t = 0
    var gid: gid_t = 0
}
/// <asm-generic/socket.h>: same value on every modern Linux arch.
private let SO_PEERCRED: Int32 = 17
#endif

public extension SocketTransport {
    /// The peer PID of a connected Unix domain socket via `LOCAL_PEERPID`.
    ///
    /// Used with ``isProcessDescendant(_:of:)`` to enforce the `cmuxOnly`
    /// access mode's ancestry check on accepted clients:
    ///
    /// ```swift
    /// if let pid = transport.peerProcessID(of: clientSocket),
    ///    !transport.isProcessDescendant(pid, of: getpid()) {
    ///     // refuse: client was not started inside cmux
    /// }
    /// ```
    /// - Parameter socket: A connected Unix domain socket descriptor.
    /// - Returns: The peer's PID, or `nil` when the lookup failed (commonly
    ///   because the peer already disconnected).
    func peerProcessID(of socket: Int32) -> pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        if result != 0 || pid <= 0 {
            return nil
        }
        return pid
        #else
        // Linux: SO_PEERCRED returns pid, uid and gid in one struct.
        var cred = LinuxUcred()
        var credLen = socklen_t(MemoryLayout<LinuxUcred>.size)
        let result = getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &cred, &credLen)
        if result != 0 || cred.pid <= 0 {
            return nil
        }
        return cred.pid
        #endif
    }

    /// Whether the socket's peer ran as the same UID as this process, via
    /// `LOCAL_PEERCRED`. Works even after the peer has disconnected (unlike
    /// `LOCAL_PEERPID`).
    ///
    /// The fallback check when ``peerProcessID(of:)`` returns `nil` because a
    /// short-lived client already disconnected; same security boundary as the
    /// socket file's 0600 permissions.
    /// - Parameter socket: A connected Unix domain socket descriptor.
    /// - Returns: `true` when the peer's effective UID matches `getuid()`.
    func peerHasSameUID(_ socket: Int32) -> Bool {
        #if canImport(Darwin)
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.cr_uid == getuid()
        #else
        var cred = LinuxUcred()
        var credLen = socklen_t(MemoryLayout<LinuxUcred>.size)
        let result = getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &cred, &credLen)
        guard result == 0 else { return false }
        return cred.uid == getuid()
        #endif
    }

    /// Whether `pid` is `ancestorPid` or one of its descendants, walking the
    /// process tree via `sysctl`.
    ///
    /// Pairs with ``peerProcessID(of:)`` for the `cmuxOnly` ancestry check;
    /// see that symbol for a usage example.
    /// - Parameters:
    ///   - pid: The process to test.
    ///   - ancestorPid: The candidate ancestor (the cmux process).
    /// - Returns: `true` when `pid`'s parent chain reaches `ancestorPid`
    ///   within 128 levels.
    func isProcessDescendant(_ pid: pid_t, of ancestorPid: pid_t) -> Bool {
        var current = pid
        // Walk up to 128 levels to avoid infinite loops from kernel bugs
        for _ in 0..<128 {
            if current == ancestorPid {
                return true
            }
            if current <= 1 {
                return false
            }
            let parent = parentProcessID(of: current)
            if parent == current || parent < 0 {
                return false
            }
            current = parent
        }
        return false
    }

    /// The parent PID of `pid` via `sysctl`, or `-1` on failure.
    private func parentProcessID(of pid: pid_t) -> pid_t {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return -1
        }
        return info.kp_eproc.e_ppid
        #else
        // Linux: field 4 of /proc/<pid>/stat. The comm field (2) can hold
        // spaces and parens, so parse from AFTER the last ')'.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return -1 }
        let rest = stat[stat.index(after: close)...].split(separator: " ")
        guard rest.count >= 2, let ppid = pid_t(rest[1]) else { return -1 }
        return ppid
        #endif
    }
}
