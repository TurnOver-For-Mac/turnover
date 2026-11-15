// SPDX-License-Identifier: GPL-3.0-or-later
// `turnover-plugin-host --self-test`: apply the sandbox, then try the things a script must never be able to do and
// check that JavaScript still runs. build.sh runs it, so a host that cannot sandbox itself stops the build.
// One line per check; exit 0 only if every forbidden thing was refused (by the sandbox: EPERM or EACCES, so a
// path that merely does not exist cannot pass) and the JavaScript ran.
import Foundation
import JavaScriptCore

enum SelfTest {
    static func run() -> Int32 {
        // Looked up before the sandbox, which may not allow the lookup.
        let home = NSHomeDirectory()
        let temporary = "/tmp/turnover-plugin-host-self-test-\(getpid())"
        if let reason = Sandbox.apply() {
            print("FAIL the sandbox could not be applied: \(reason)")
            return 3
        }
        var allPassed = true
        func report(_ passed: Bool, _ what: String) {
            print("\(passed ? "ok  " : "FAIL") \(what)")
            if !passed { allPassed = false }
        }
        func refused(_ code: Int32) -> Bool { code == EPERM || code == EACCES }

        let readFD = open(home, O_RDONLY)
        let readError = errno
        if readFD >= 0 { close(readFD) }
        report(readFD < 0 && refused(readError), "opening the home folder was refused" + (readFD >= 0 ? " (it was allowed)" : " (error \(readError))"))

        let writeFD = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        let writeError = errno
        if writeFD >= 0 { close(writeFD); unlink(temporary) }
        report(writeFD < 0 && refused(writeError), "writing a file in /tmp was refused" + (writeFD >= 0 ? " (it was allowed)" : " (error \(writeError))"))

        // Port 9 has nothing listening: ECONNREFUSED would mean the sandbox let the attempt through.
        var networkRefused = false
        var networkNote = ""
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 {
            networkRefused = refused(errno); networkNote = "socket error \(errno)"
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            networkRefused = result != 0 && refused(errno)
            networkNote = result == 0 ? "connected" : "error \(errno)"
            close(sock)
        }
        report(networkRefused, "connecting to 127.0.0.1 was refused (\(networkNote))")

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        let spawnResult = posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, nil)
        argv.forEach { free($0) }
        if spawnResult == 0 { var status: Int32 = 0; waitpid(pid, &status, 0) }
        report(spawnResult != 0, "starting /usr/bin/true was refused" + (spawnResult == 0 ? " (it was allowed)" : " (error \(spawnResult))"))

        let context = JSContext()
        let value = context?.evaluateScript("[1, 2, 3].map(x => x * 2).join(',') + ' ' + new Date(0).toISOString() + ' ' + new Intl.NumberFormat('en').format(1234.5)")?.toString()
        report(value == "2,4,6 1970-01-01T00:00:00.000Z 1,234.5", "JavaScript ran (\(value ?? "no answer"))")
        return allPassed ? 0 : 1
    }
}
