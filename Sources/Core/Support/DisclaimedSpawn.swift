// SPDX-License-Identifier: GPL-3.0-or-later
// Starting a helper program so it does NOT inherit TurnOver's permissions (the plugin design notes 12; probed 13 Oct 2026: the
// Kokoro helper, started with Process, was trusted for Accessibility and Input Monitoring, because macOS counts a
// child against its "responsible" parent). posix_spawn with the responsibility disclaimed, as browsers start their
// content processes, makes the helper answer for itself: it has no permissions unless granted its own.
import Foundation
import Darwin

public enum DisclaimedSpawn {
    public struct Child { public let pid: pid_t; public let stdin: FileHandle; public let stdout: FileHandle; public let stderr: FileHandle }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let setDisclaim: SetDisclaim? = {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(f, to: SetDisclaim.self)
    }()

    /// Start `path` with `arguments`, its three standard streams as pipes, in `directory`. `exited` is called (on a
    /// background thread) with the exit status when it ends. Nil if it couldn't start; `disclaimed` says whether the
    /// permissions link was cut (false only where macOS lacks the call).
    public static func run(_ path: String, arguments: [String], directory: String?, exited: @escaping @Sendable (Int32) -> Void) -> (child: Child, disclaimed: Bool)? {
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe.fileHandleForWriting.fileDescriptor, 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Close every other descriptor TurnOver has open (its log, its sockets) in the child, and give it the default
        // signal handling and an empty mask: TurnOver ignores SIGTERM (it handles it itself), and a spawned child
        // inherits that, so it couldn't be stopped (13 Oct 2026). Process does this for itself; posix_spawn doesn't.
        var all = sigset_t(); sigfillset(&all)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let disclaimed = setDisclaim.map { $0(&attr, 1) == 0 } ?? false
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let r = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        // The child has its ends; close ours of them.
        try? inPipe.fileHandleForReading.close(); try? outPipe.fileHandleForWriting.close(); try? errPipe.fileHandleForWriting.close()
        guard r == 0 else { return nil }
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            exited(status)
        }
        return (Child(pid: pid, stdin: inPipe.fileHandleForWriting, stdout: outPipe.fileHandleForReading, stderr: errPipe.fileHandleForReading), disclaimed)
    }
}
