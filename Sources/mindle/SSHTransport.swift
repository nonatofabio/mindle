import Foundation

struct ProcessResult { let status: Int32; let stdout: Data; let stderr: Data }

struct RemoteDocumentListing: Equatable {
    let root: SSHTarget
    let files: [SSHTarget]
}

struct RemoteAssetFetchFailure: Equatable {
    let path: String
    let message: String
}

struct RemoteAssetFetchReport: Equatable {
    let failures: [RemoteAssetFetchFailure]
    let fetchedCount: Int
    let skippedForLimit: Int
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
    case missingRemoteRoot(String)
    case remoteAssetOutsideRoot(String)
    case remoteAssetResolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "SSH command failed." : trimmed
        case .launchFailed(let m):
            return "Couldn't launch ssh/scp: \(m)"
        case .invalidListing:
            return "SSH returned an invalid file listing."
        case .missingRemoteRoot(let path):
            return "The configured SSH profile root doesn't exist: \(path)"
        case .remoteAssetOutsideRoot(let path):
            return "Remote image resolves outside the configured SSH root: \(path)"
        case .remoteAssetResolutionFailed(let path):
            return "Couldn't resolve remote image path: \(path)"
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
    static let resolvedAssetMarker = "\u{1e}MINDLE_ASSET\u{1e}"
    static let missingRootExitStatus: Int32 = 72
    static let assetOutsideRootExitStatus: Int32 = 73
    static let assetResolutionExitStatus: Int32 = 74
    static let browsableDocumentExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "pdf"
    ]
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
        let extensions = browsableDocumentExtensions.sorted().map {
            "-iname \(shellSingleQuote("*.\($0)"))"
        }.joined(separator: " -o ")
        let configuredRoot = shellSingleQuote(profile.rootPath)
        let command = """
        root=\(configuredRoot); \
        if [ ! -d "$root" ]; then \
        printf 'Mindle SSH profile root does not exist: %s\\n' "$root" >&2; \
        exit \(missingRootExitStatus); \
        fi; \
        printf '\\036MINDLE_ROOT\\036%s\\0' "$root"; \
        find "$root" -path '*/.*' -prune -o -type f \\( \(extensions) \\) -print0
        """
        return sshFlags + [profile.hostname, command]
    }

    static func resolveAssetArgs(_ target: SSHTarget, profileRoot: SSHTarget) -> [String] {
        let configuredRoot = shellSingleQuote(profileRoot.remotePath)
        let configuredAsset = shellSingleQuote(target.remotePath)
        let command = """
        root=\(configuredRoot); asset=\(configuredAsset); \
        if [ ! -d "$root" ]; then \
        printf 'Mindle SSH profile root does not exist: %s\\n' "$root" >&2; \
        exit \(missingRootExitStatus); \
        fi; \
        root_real=$(cd "$root" && pwd -P) || exit \(assetResolutionExitStatus); \
        asset_real=$(realpath "$asset" 2>/dev/null) || { \
        printf 'Mindle remote image path could not be resolved: %s\\n' "$asset" >&2; \
        exit \(assetResolutionExitStatus); \
        }; \
        inside=0; \
        if [ "$root_real" = "/" ]; then inside=1; \
        else case "$asset_real" in "$root_real"/*) inside=1 ;; esac; fi; \
        if [ "$inside" -ne 1 ]; then \
        printf 'Mindle remote image resolves outside profile root: %s\\n' "$asset" >&2; \
        exit \(assetOutsideRootExitStatus); \
        fi; \
        printf '\\036MINDLE_ROOT\\036%s\\0\\036MINDLE_ASSET\\036%s\\0' "$root_real" "$asset_real"
        """
        return sshFlags + [target.userHost, command]
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
        if result.status == missingRootExitStatus {
            throw SSHTransportError.missingRemoteRoot(profile.rootPath)
        }
        guard result.status == 0 else {
            throw SSHTransportError.nonZeroExit(
                status: result.status,
                stderr: String(data: result.stderr, encoding: .utf8) ?? ""
            )
        }

        guard let output = String(data: result.stdout, encoding: .utf8) else {
            throw SSHTransportError.invalidListing
        }
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        let rootPaths = tokens.compactMap { token -> String? in
            guard let marker = token.range(of: listingRootMarker) else { return nil }
            return String(token[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard rootPaths.count == 1,
              let root = SSHTarget(userHost: profile.hostname, remotePath: rootPaths[0]),
              root == profile.rootTarget else {
            throw SSHTransportError.invalidListing
        }

        let files = tokens.compactMap { token -> SSHTarget? in
                guard !token.contains(listingRootMarker) else { return nil }
                let path = token.trimmingCharacters(in: .newlines)
                guard let target = SSHTarget(userHost: root.userHost, remotePath: path),
                      profile.contains(target),
                      target.remotePath != root.remotePath,
                      browsableDocumentExtensions.contains(
                        (target.remotePath as NSString).pathExtension.lowercased()
                      ) else {
                    return nil
                }
                return target
            }
            .sorted {
                $0.remotePath.localizedCaseInsensitiveCompare($1.remotePath) == .orderedAscending
            }
        return RemoteDocumentListing(root: root, files: files)
    }

    static func fetchReferencedImages(
        in markdown: String,
        for document: SSHTarget,
        profileRoot: SSHTarget,
        cacheDir: URL,
        runner: ProcessRunner = SystemProcessRunner()
    ) async -> RemoteAssetFetchReport {
        let relativePaths = RemoteMarkdownAssets.relativePaths(in: markdown)
        let selectedPaths = Array(relativePaths.prefix(RemoteMarkdownAssets.maxAssetsPerDocument))
        var failures: [RemoteAssetFetchFailure] = []
        var fetchedCount = 0

        for relativePath in selectedPaths {
            let target: SSHTarget
            do {
                target = try RemoteMarkdownAssets.target(
                    for: relativePath,
                    from: document,
                    confinedTo: profileRoot
                )
            } catch {
                failures.append(RemoteAssetFetchFailure(
                    path: relativePath,
                    message: error.localizedDescription
                ))
                continue
            }

            do {
                let resolvedTarget = try await resolveRemoteAsset(
                    target,
                    profileRoot: profileRoot,
                    runner: runner
                )
                try await fetch(
                    resolvedTarget,
                    to: target.proxyURL(cacheDir: cacheDir),
                    runner: runner
                )
                fetchedCount += 1
            } catch {
                failures.append(RemoteAssetFetchFailure(
                    path: relativePath,
                    message: error.localizedDescription
                ))
            }
        }

        return RemoteAssetFetchReport(
            failures: failures,
            fetchedCount: fetchedCount,
            skippedForLimit: max(0, relativePaths.count - selectedPaths.count)
        )
    }

    private static func resolveRemoteAsset(
        _ target: SSHTarget,
        profileRoot: SSHTarget,
        runner: ProcessRunner
    ) async throws -> SSHTarget {
        let result = try await runner.run(
            launchPath: sshPath,
            arguments: resolveAssetArgs(target, profileRoot: profileRoot)
        )
        switch result.status {
        case missingRootExitStatus:
            throw SSHTransportError.missingRemoteRoot(profileRoot.remotePath)
        case assetOutsideRootExitStatus:
            throw SSHTransportError.remoteAssetOutsideRoot(target.remotePath)
        case assetResolutionExitStatus:
            throw SSHTransportError.remoteAssetResolutionFailed(target.remotePath)
        case 0:
            break
        default:
            throw SSHTransportError.nonZeroExit(
                status: result.status,
                stderr: String(data: result.stderr, encoding: .utf8) ?? ""
            )
        }

        guard let output = String(data: result.stdout, encoding: .utf8) else {
            throw SSHTransportError.remoteAssetResolutionFailed(target.remotePath)
        }
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true)
        let resolvedRoots = tokens.compactMap { token -> String? in
            guard let marker = token.range(of: listingRootMarker) else { return nil }
            return String(token[marker.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let resolvedPaths = tokens.compactMap { token -> String? in
                guard let marker = token.range(of: resolvedAssetMarker) else { return nil }
                return String(token[marker.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        guard resolvedRoots.count == 1,
              resolvedPaths.count == 1,
              let resolvedRoot = SSHTarget(
                userHost: target.userHost,
                remotePath: resolvedRoots[0]
              ),
              let resolved = SSHTarget(
                userHost: target.userHost,
                remotePath: resolvedPaths[0]
              ) else {
            throw SSHTransportError.remoteAssetResolutionFailed(target.remotePath)
        }
        try RemoteMarkdownAssets.validate(
            resolved,
            confinedTo: resolvedRoot,
            originalPath: target.remotePath
        )
        return resolved
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
