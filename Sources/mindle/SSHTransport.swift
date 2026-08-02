import Foundation

struct ProcessResult { let status: Int32; let stdout: Data; let stderr: Data }

struct RemoteAssetFetchFailure: Equatable {
    let path: String
    let message: String
}

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
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: SSHTransportError.launchFailed(error.localizedDescription))
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let reads = DispatchGroup()
                let lock = NSLock()
                var stdout = Data()
                var stderr = Data()

                reads.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    lock.lock()
                    stdout = data
                    lock.unlock()
                    reads.leave()
                }
                reads.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = err.fileHandleForReading.readDataToEndOfFile()
                    lock.lock()
                    stderr = data
                    lock.unlock()
                    reads.leave()
                }

                proc.waitUntilExit()
                reads.wait()
                cont.resume(returning: ProcessResult(
                    status: proc.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }
        }
    }
}

enum SSHTransportError: Error, LocalizedError {
    case nonZeroExit(status: Int32, stderr: String)
    case launchFailed(String)
    case invalidListing

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "SSH command failed." : trimmed
        case .launchFailed(let m):
            return "Couldn't launch ssh/scp: \(m)"
        case .invalidListing:
            return "SSH returned an invalid file listing."
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
    static let listingRootMarker = "\u{1e}MINDLE_ROOT\u{1e}"
    private static let cacheWriteLock = NSLock()

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
    /// Remote path unquoted for the same reason as `fetchArgs`. Flags MUST
    /// precede the positional source/dest: BSD/macOS `getopt` stops option
    /// parsing at the first non-option argument, so a leading local path
    /// would make scp treat `-o …` as extra source files (`stat local "-o"`).
    static func pushArgs(_ proxy: URL, to target: SSHTarget) -> [String] {
        let remoteTmp = target.remotePath + remoteTmpSuffix
        return sshFlags + [proxy.path, "\(target.userHost):\(remoteTmp)"]
    }

    /// `ssh <flags> user@host "mv '/remote/path.tmp' '/remote/path'"`
    /// The remote `mv` runs through the remote shell, so both paths are
    /// single-quoted for that shell.
    static func remoteMvArgs(_ target: SSHTarget) -> [String] {
        let remoteTmp = target.remotePath + remoteTmpSuffix
        let cmd = "mv \(shellSingleQuote(remoteTmp)) \(shellSingleQuote(target.remotePath))"
        return sshFlags + [target.userHost, cmd]
    }

    static func listDocumentsArgs(_ profile: SSHProfile) -> [String] {
        let extensions = FileTreeBuilder.browsableExtensions.sorted().map {
            "-iname \(shellSingleQuote("*.\($0)"))"
        }.joined(separator: " -o ")
        let configuredRoot = shellSingleQuote(profile.rootPath)
        let command = """
        root=\(configuredRoot); \
        if [ ! -d "$root" ]; then root=$HOME; fi; \
        printf '\\036MINDLE_ROOT\\036%s\\0' "$root"; \
        find "$root" -path '*/.*' -prune -o -type f \\( \(extensions) \\) -print0
        """
        return sshFlags + [profile.hostname, command]
    }

    // MARK: Operations

    /// Fetch the remote file to `proxyURL` atomically: scp to a sibling
    /// temp, then move onto the proxy so a partial transfer never clobbers
    /// a previously-good copy.
    static func fetch(_ target: SSHTarget, to proxyURL: URL, runner: ProcessRunner = SystemProcessRunner()) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: proxyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = proxyURL.appendingPathExtension("fetch-\(UUID().uuidString)")
        let res = try await runner.run(launchPath: scpPath, arguments: fetchArgs(target, tmp: tmp))
        guard res.status == 0 else {
            try? fm.removeItem(at: tmp)
            throw SSHTransportError.nonZeroExit(status: res.status,
                  stderr: String(data: res.stderr, encoding: .utf8) ?? "")
        }
        try cacheWriteLock.withLock {
            if fm.fileExists(atPath: proxyURL.path) {
                try fm.removeItem(at: proxyURL)
            }
            try fm.moveItem(at: tmp, to: proxyURL)
        }
    }

    static func listDocuments(
        in profile: SSHProfile,
        runner: ProcessRunner = SystemProcessRunner()
    ) async throws -> RemoteDocumentListing {
        let result = try await runner.run(
            launchPath: sshPath,
            arguments: listDocumentsArgs(profile)
        )
        guard result.status == 0 else {
            throw SSHTransportError.nonZeroExit(
                status: result.status,
                stderr: String(data: result.stderr, encoding: .utf8) ?? ""
            )
        }

        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard let rootPath = tokens.compactMap({ token -> String? in
            guard let marker = token.range(of: listingRootMarker) else { return nil }
            return String(token[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }).first,
              let root = SSHTarget(userHost: profile.hostname, remotePath: rootPath) else {
            throw SSHTransportError.invalidListing
        }

        let rootPrefix = root.remotePath.hasSuffix("/")
            ? root.remotePath
            : root.remotePath + "/"
        let files = tokens.compactMap { token -> SSHTarget? in
                guard !token.contains(listingRootMarker) else { return nil }
                let path = token.trimmingCharacters(in: .newlines)
                guard path.hasPrefix(rootPrefix) else { return nil }
                return SSHTarget(userHost: root.userHost, remotePath: path)
            }
            .sorted { $0.remotePath.localizedCaseInsensitiveCompare($1.remotePath) == .orderedAscending }
        return RemoteDocumentListing(root: root, files: files)
    }

    static func fetchReferencedImages(
        in markdown: String,
        for document: SSHTarget,
        cacheDir: URL,
        runner: ProcessRunner = SystemProcessRunner()
    ) async -> [RemoteAssetFetchFailure] {
        var failures: [RemoteAssetFetchFailure] = []
        for relativePath in RemoteMarkdownAssets.relativePaths(in: markdown) {
            guard let target = RemoteMarkdownAssets.target(
                for: relativePath,
                from: document
            ) else {
                continue
            }
            do {
                try await fetch(target, to: target.proxyURL(cacheDir: cacheDir), runner: runner)
            } catch {
                failures.append(RemoteAssetFetchFailure(
                    path: relativePath,
                    message: error.localizedDescription
                ))
            }
        }
        return failures
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
