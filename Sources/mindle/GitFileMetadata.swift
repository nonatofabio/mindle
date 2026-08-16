import Foundation

struct GitFileChanges: Equatable, Sendable {
    let additions: Int?
    let deletions: Int?
    let isUntracked: Bool

    var badgeText: String {
        if isUntracked { return "+new" }
        guard let additions, let deletions else { return "±" }
        return "+\(additions) −\(deletions)"
    }
}

struct GitFileMetadata: Equatable, Sendable {
    var changes: GitFileChanges? = nil
    var lastEditedAt: Date? = nil
}

struct GitMetadataSnapshot: Equatable, Sendable {
    let files: [URL: GitFileMetadata]

    static let empty = GitMetadataSnapshot(files: [:])
}

struct GitCommandResult: Sendable {
    let status: Int32
    let output: Data
}

typealias GitCommandRunner = @Sendable ([String]) async -> GitCommandResult

enum GitLastEditedFormatter {
    static func badgeText(since date: Date, now: Date = Date()) -> String {
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        if days < 7 { return "\(days)d" }
        if days < 30 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }
}

enum GitMetadataCollector {
    static func collect(
        for browserRoot: URL,
        runner: @escaping GitCommandRunner = liveRunner
    ) async -> GitMetadataSnapshot {
        guard !Task.isCancelled else { return .empty }
        let normalizedRoot = browserRoot.standardizedFileURL

        return await PerformanceTrace.measure("GitMetadataBuild") {
            async let changes = workingTreeChanges(
                browserRoot: normalizedRoot,
                runner: runner
            )
            async let timestamps = lastEditedTimestamps(
                browserRoot: normalizedRoot,
                runner: runner
            )

            let (collectedChanges, collectedTimestamps) = await (changes, timestamps)
            guard !Task.isCancelled else { return .empty }

            var metadata: [URL: GitFileMetadata] = [:]
            for (relativePath, change) in collectedChanges {
                guard let url = fileURL(relativePath, under: normalizedRoot) else { continue }
                metadata[url, default: GitFileMetadata()].changes = change
            }
            for (relativePath, timestamp) in collectedTimestamps {
                guard let url = fileURL(relativePath, under: normalizedRoot) else { continue }
                metadata[url, default: GitFileMetadata()].lastEditedAt = Date(
                    timeIntervalSince1970: TimeInterval(timestamp)
                )
            }
            return GitMetadataSnapshot(files: metadata)
        }
    }

    static func parseNumstat(_ data: Data) -> [String: GitFileChanges] {
        var changes: [String: GitFileChanges] = [:]
        for record in nullSeparatedStrings(data) {
            let fields = record.split(
                separator: "\t",
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            guard fields.count == 3 else { continue }
            changes[String(fields[2])] = GitFileChanges(
                additions: Int(fields[0]),
                deletions: Int(fields[1]),
                isUntracked: false
            )
        }
        return changes
    }

    static func parseUntrackedPaths(_ data: Data) -> [String] {
        nullSeparatedStrings(data).compactMap { record in
            guard record.hasPrefix("?? ") else { return nil }
            return String(record.dropFirst(3))
        }
    }

    static func parseLastEdited(_ data: Data) -> [String: Int64] {
        var timestamps: [String: Int64] = [:]
        var currentTimestamp: Int64?

        for token in nullSeparatedStrings(data, preservingEmpty: true) {
            if token.first == "\u{1e}" {
                currentTimestamp = Int64(token.dropFirst())
                continue
            }

            let path = token.trimmingCharacters(in: .newlines)
            guard !path.isEmpty, let currentTimestamp, timestamps[path] == nil else { continue }
            timestamps[path] = currentTimestamp
        }
        return timestamps
    }

    private static func workingTreeChanges(
        browserRoot: URL,
        runner: @escaping GitCommandRunner
    ) async -> [String: GitFileChanges] {
        guard !Task.isCancelled else { return [:] }
        let pathspecs = supportedFilePathspecs
        let headDiff = await runner(
            [
                "-C", browserRoot.path,
                "diff", "--relative", "--numstat", "-z", "--no-renames", "HEAD", "--"
            ] + pathspecs
        )

        var changes: [String: GitFileChanges]
        if headDiff.status == 0 {
            changes = parseNumstat(headDiff.output)
        } else {
            changes = [:]
            let cached = await runner(
                [
                    "-C", browserRoot.path,
                    "diff", "--relative", "--numstat", "-z", "--no-renames", "--cached", "--"
                ] + pathspecs
            )
            merge(parseNumstat(cached.output), into: &changes)
            guard !Task.isCancelled else { return changes }
            let unstaged = await runner(
                [
                    "-C", browserRoot.path,
                    "diff", "--relative", "--numstat", "-z", "--no-renames", "--"
                ] + pathspecs
            )
            merge(parseNumstat(unstaged.output), into: &changes)
        }

        guard !Task.isCancelled else { return changes }
        let status = await runner(
            [
                "-C", browserRoot.path,
                "ls-files", "--others", "--exclude-standard", "-z", "--"
            ] + pathspecs
        )
        for path in nullSeparatedStrings(status.output) {
            changes[path] = GitFileChanges(additions: nil, deletions: nil, isUntracked: true)
        }
        return changes
    }

    private static func lastEditedTimestamps(
        browserRoot: URL,
        runner: @escaping GitCommandRunner
    ) async -> [String: Int64] {
        guard !Task.isCancelled else { return [:] }
        let result = await runner(
            [
                "-C", browserRoot.path,
                "log", "--relative", "--format=%x1e%ct%x00", "--name-only", "-z",
                "--no-renames", "--diff-filter=AM", "--"
            ] + supportedFilePathspecs
        )
        guard result.status == 0 else { return [:] }
        return parseLastEdited(result.output)
    }

    private static func fileURL(_ relativePath: String, under root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard FileTreeBuilder.isDescendant(url, of: root) else { return nil }
        return url
    }

    private static func merge(
        _ incoming: [String: GitFileChanges],
        into changes: inout [String: GitFileChanges]
    ) {
        for (path, value) in incoming {
            guard let existing = changes[path],
                  let existingAdditions = existing.additions,
                  let existingDeletions = existing.deletions,
                  let additions = value.additions,
                  let deletions = value.deletions else {
                changes[path] = value
                continue
            }
            changes[path] = GitFileChanges(
                additions: existingAdditions + additions,
                deletions: existingDeletions + deletions,
                isUntracked: false
            )
        }
    }

    private static let liveRunner: GitCommandRunner = { arguments in
        await runGit(arguments)
    }

    private static func runGit(_ arguments: [String]) async -> GitCommandResult {
        let operation = GitCommandOperation(arguments: arguments)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.start { continuation.resume(returning: $0) }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private static func nullSeparatedStrings(
        _ data: Data,
        preservingEmpty: Bool = false
    ) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: !preservingEmpty).compactMap {
            String(data: $0, encoding: .utf8)
        }
    }

    private static var supportedFilePathspecs: [String] {
        FileTreeBuilder.browsableExtensions.sorted().flatMap {
            [
                ":(glob,icase)*.\($0)",
                ":(glob,icase)**/*.\($0)"
            ]
        }
    }
}

private final class GitCommandOperation: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let lock = NSLock()
    private var cancelRequested = false
    private var finished = false
    private var collectedOutput = Data()
    private var reachedEndOfOutput = false
    private var terminationStatus: Int32?

    init(arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = outputPipe.fileHandleForWriting
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C"
        ]) { _, new in new }
    }

    func start(completion: @escaping @Sendable (GitCommandResult) -> Void) {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                self?.markEndOfOutput(completion: completion)
            } else {
                self?.appendOutput(chunk)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.markTerminated(
                status: process.terminationStatus,
                completion: completion
            )
            try? self?.outputPipe.fileHandleForWriting.close()
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            finish(GitCommandResult(status: -1, output: Data()), completion: completion)
            return
        }

        lock.lock()
        let shouldCancel = cancelRequested
        lock.unlock()
        if shouldCancel, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let shouldTerminate = !finished && process.isRunning
        lock.unlock()
        if shouldTerminate {
            process.terminate()
        }
    }

    private func appendOutput(_ data: Data) {
        lock.lock()
        collectedOutput.append(data)
        lock.unlock()
    }

    private func markEndOfOutput(
        completion: @escaping @Sendable (GitCommandResult) -> Void
    ) {
        lock.lock()
        reachedEndOfOutput = true
        let result = completedResultLocked()
        lock.unlock()
        completeIfReady(result, completion: completion)
    }

    private func markTerminated(
        status: Int32,
        completion: @escaping @Sendable (GitCommandResult) -> Void
    ) {
        lock.lock()
        terminationStatus = status
        let result = completedResultLocked()
        lock.unlock()
        completeIfReady(result, completion: completion)
    }

    private func completedResultLocked() -> GitCommandResult? {
        guard !finished, reachedEndOfOutput, let terminationStatus else { return nil }
        finished = true
        return GitCommandResult(status: terminationStatus, output: collectedOutput)
    }

    private func completeIfReady(
        _ result: GitCommandResult?,
        completion: @escaping @Sendable (GitCommandResult) -> Void
    ) {
        guard let result else { return }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? outputPipe.fileHandleForReading.close()
        completion(result)
    }

    private func finish(
        _ result: GitCommandResult,
        completion: @escaping @Sendable (GitCommandResult) -> Void
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        completion(result)
    }
}
