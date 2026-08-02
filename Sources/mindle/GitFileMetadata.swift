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
        includeChanges: Bool,
        includeLastEdited: Bool
    ) -> GitMetadataSnapshot {
        guard includeChanges || includeLastEdited,
              !Task.isCancelled,
              let repositoryRoot = repositoryRoot(containing: browserRoot) else {
            return .empty
        }

        var metadata: [URL: GitFileMetadata] = [:]
        if includeChanges {
            let changes = workingTreeChanges(
                browserRoot: browserRoot
            )
            for (relativePath, change) in changes {
                let url = repositoryRoot.appendingPathComponent(relativePath).standardizedFileURL
                guard FileTreeBuilder.isDescendant(url, of: browserRoot) else { continue }
                metadata[url, default: GitFileMetadata()].changes = change
            }
        }

        if includeLastEdited && !Task.isCancelled {
            let timestamps = lastEditedTimestamps(browserRoot: browserRoot)
            for (relativePath, timestamp) in timestamps {
                let url = repositoryRoot.appendingPathComponent(relativePath).standardizedFileURL
                guard FileTreeBuilder.isDescendant(url, of: browserRoot) else { continue }
                metadata[url, default: GitFileMetadata()].lastEditedAt = Date(
                    timeIntervalSince1970: TimeInterval(timestamp)
                )
            }
        }

        return GitMetadataSnapshot(files: metadata)
    }

    static func parseNumstat(_ data: Data) -> [String: GitFileChanges] {
        var changes: [String: GitFileChanges] = [:]
        for record in nullSeparatedStrings(data) {
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let path = String(fields[2])
            changes[path] = GitFileChanges(
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

    private static func repositoryRoot(containing url: URL) -> URL? {
        let result = runGit(["-C", url.path, "rev-parse", "--show-toplevel"])
        guard result.status == 0,
              let path = String(data: result.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func workingTreeChanges(
        browserRoot: URL
    ) -> [String: GitFileChanges] {
        guard !Task.isCancelled else { return [:] }
        let pathspecs = supportedFilePathspecs
        let headDiff = runGit(
            ["-C", browserRoot.path, "diff", "--numstat", "-z", "--no-renames", "HEAD", "--"]
                + pathspecs
        )

        var changes: [String: GitFileChanges]
        if headDiff.status == 0 {
            changes = parseNumstat(headDiff.output)
        } else {
            changes = [:]
            merge(parseNumstat(runGit(
                ["-C", browserRoot.path, "diff", "--numstat", "-z", "--no-renames", "--cached", "--"]
                    + pathspecs
            ).output),
                into: &changes
            )
            merge(parseNumstat(runGit(
                ["-C", browserRoot.path, "diff", "--numstat", "-z", "--no-renames", "--"]
                    + pathspecs
            ).output),
                into: &changes
            )
        }

        guard !Task.isCancelled else { return changes }
        let status = runGit(
            ["-C", browserRoot.path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--"]
                + pathspecs
        )
        for path in parseUntrackedPaths(status.output) {
            changes[path] = untrackedChanges()
        }
        return changes
    }

    private static func lastEditedTimestamps(
        browserRoot: URL
    ) -> [String: Int64] {
        guard !Task.isCancelled else { return [:] }
        let result = runGit(
            [
                "-C", browserRoot.path,
                "log", "--format=%x1e%ct%x00", "--name-only", "-z",
                "--no-renames", "--diff-filter=AM", "--"
            ] + supportedFilePathspecs
        )
        guard result.status == 0 else { return [:] }
        return parseLastEdited(result.output)
    }

    private static func untrackedChanges() -> GitFileChanges {
        GitFileChanges(additions: nil, deletions: nil, isUntracked: true)
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

    private static func runGit(_ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mindle-git-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            return (-1, Data())
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C"
        ]) { _, new in new }

        do {
            try process.run()
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            try output.synchronize()
            guard !Task.isCancelled else { return (-1, Data()) }
            let data = (try? Data(contentsOf: outputURL, options: .mappedIfSafe)) ?? Data()
            return (process.terminationStatus, data)
        } catch {
            return (-1, Data())
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
        FileTreeBuilder.browsableExtensions.sorted().map {
            ":(glob,icase)**/*.\($0)"
        }
    }
}
