import Foundation

struct ProcessResult { let status: Int32; let stdout: Data; let stderr: Data }

/// Runs an external process. Behind a protocol so tests inject a fake —
/// real ssh/scp I/O is not unit-testable.
protocol ProcessRunner {
    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult
}

struct SystemProcessRunner: ProcessRunner {
    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = arguments
            let out = Pipe(); let err = Pipe()
            proc.standardOutput = out; proc.standardError = err
            proc.terminationHandler = { p in
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: o, stderr: e))
            }
            do { try proc.run() } catch {
                cont.resume(throwing: SSHTransportError.launchFailed(error.localizedDescription))
            }
        }
    }
}

enum SSHTransportError: Error, LocalizedError {
    case nonZeroExit(status: Int32, stderr: String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "SSH command failed." : trimmed
        case .launchFailed(let m):
            return "Couldn't launch ssh/scp: \(m)"
        }
    }
}

enum SSHTransport {
    /// Always non-interactive + fail-fast: key/agent auth only, no hidden
    /// password prompts, 10s connect ceiling.
    static let sshFlags = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    static let scpPath = "/usr/bin/scp"
    static let sshPath = "/usr/bin/ssh"
    static let remoteTmpSuffix = ".mindle-tmp"

    /// POSIX single-quote: wrap in '…', escaping embedded ' as '\''.
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Pure argv builders (unit-tested)

    /// `scp <flags> user@host:/remote/path <localTmp>`
    ///
    /// The remote path is NOT shell-quoted: modern scp (OpenSSH 9+) defaults
    /// to the SFTP protocol, which treats the remote path literally (no
    /// remote shell to strip quotes), and we invoke scp via `Process` (no
    /// local shell either) — so the whole `host:path` is one argv entry and
    /// spaces are safe as-is. Quoting it would embed literal `'` characters
    /// in the filename and fail with "No such file or directory".
    static func fetchArgs(_ target: SSHTarget, tmp: URL) -> [String] {
        sshFlags + ["\(target.userHost):\(target.remotePath)", tmp.path]
    }

    /// `scp <flags> <localProxy> user@host:/remote/path.mindle-tmp`
    /// Remote path unquoted for the same reason as `fetchArgs`.
    static func pushArgs(_ proxy: URL, to target: SSHTarget) -> [String] {
        let remoteTmp = target.remotePath + remoteTmpSuffix
        return [proxy.path] + sshFlags + ["\(target.userHost):\(remoteTmp)"]
    }

    /// `ssh <flags> user@host "mv '/remote/path.tmp' '/remote/path'"`
    /// The remote `mv` runs through the remote shell, so both paths are
    /// single-quoted for that shell.
    static func remoteMvArgs(_ target: SSHTarget) -> [String] {
        let remoteTmp = target.remotePath + remoteTmpSuffix
        let cmd = "mv \(shellSingleQuote(remoteTmp)) \(shellSingleQuote(target.remotePath))"
        return sshFlags + [target.userHost, cmd]
    }

    // MARK: Operations

    /// Fetch the remote file to `proxyURL` atomically: scp to a sibling
    /// temp, then move onto the proxy so a partial transfer never clobbers
    /// a previously-good copy.
    static func fetch(_ target: SSHTarget, to proxyURL: URL, runner: ProcessRunner = SystemProcessRunner()) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: proxyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = proxyURL.appendingPathExtension("fetch")
        try? fm.removeItem(at: tmp)
        let res = try await runner.run(launchPath: scpPath, arguments: fetchArgs(target, tmp: tmp))
        guard res.status == 0 else {
            try? fm.removeItem(at: tmp)
            throw SSHTransportError.nonZeroExit(status: res.status,
                  stderr: String(data: res.stderr, encoding: .utf8) ?? "")
        }
        if fm.fileExists(atPath: proxyURL.path) { try fm.removeItem(at: proxyURL) }
        try fm.moveItem(at: tmp, to: proxyURL)
    }

    /// Upload `proxyURL` to a remote temp path, then remote-`mv` it onto the
    /// real path (atomic remote write — a dropped connection never truncates).
    static func push(_ proxyURL: URL, to target: SSHTarget, runner: ProcessRunner = SystemProcessRunner()) async throws {
        let up = try await runner.run(launchPath: scpPath, arguments: pushArgs(proxyURL, to: target))
        guard up.status == 0 else {
            throw SSHTransportError.nonZeroExit(status: up.status,
                  stderr: String(data: up.stderr, encoding: .utf8) ?? "")
        }
        let mv = try await runner.run(launchPath: sshPath, arguments: remoteMvArgs(target))
        guard mv.status == 0 else {
            throw SSHTransportError.nonZeroExit(status: mv.status,
                  stderr: String(data: mv.stderr, encoding: .utf8) ?? "")
        }
    }
}
