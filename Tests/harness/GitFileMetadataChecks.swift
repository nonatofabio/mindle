import Foundation

func runGitFileMetadataChecks() async -> Int {
    let checks = Checks("GitFileMetadata")

    let numstat = Data("12\t3\tdocs/a.md\u{0}-\t-\tdocs/paper.pdf\u{0}".utf8)
    let parsedChanges = GitMetadataCollector.parseNumstat(numstat)
    checks.equal(parsedChanges["docs/a.md"]?.additions, 12, "numstat additions")
    checks.equal(parsedChanges["docs/a.md"]?.deletions, 3, "numstat deletions")
    checks.equal(parsedChanges["docs/a.md"]?.badgeText, "+12 −3", "change badge")
    checks.equal(parsedChanges["docs/paper.pdf"]?.badgeText, "±", "binary badge")

    let status = Data("?? docs/new.md\u{0} M docs/existing.md\u{0}".utf8)
    checks.equal(
        GitMetadataCollector.parseUntrackedPaths(status),
        ["docs/new.md"],
        "untracked status parsing"
    )

    let historyText =
        "\u{1e}1721000000\u{0}\u{0}\ndocs/a.md\u{0}docs/b.md\u{0}"
        + "\u{1e}1710000000\u{0}\u{0}\ndocs/a.md\u{0}docs/c.md\u{0}"
    let parsedHistory = GitMetadataCollector.parseLastEdited(Data(historyText.utf8))
    checks.equal(parsedHistory["docs/a.md"], 1_721_000_000, "latest file commit wins")
    checks.equal(parsedHistory["docs/c.md"], 1_710_000_000, "older file commit retained")

    let now = Date(timeIntervalSince1970: 2_000_000)
    checks.equal(
        GitLastEditedFormatter.badgeText(since: now.addingTimeInterval(-8 * 86_400), now: now),
        "1w",
        "week badge"
    )
    checks.equal(
        GitLastEditedFormatter.badgeText(since: now.addingTimeInterval(-65 * 86_400), now: now),
        "2mo",
        "month badge"
    )
    checks.equal(
        GitLastEditedFormatter.badgeText(since: now.addingTimeInterval(86_400), now: now),
        "0d",
        "future timestamps clamp to zero"
    )

    let fakeRoot = URL(fileURLWithPath: ".build/test-fixtures/git-stub", isDirectory: true)
        .standardizedFileURL
    let runner = StubGitRunner()
    let stubSnapshot = await GitMetadataCollector.collect(
        for: fakeRoot,
        runner: { arguments in await runner.run(arguments) }
    )
    let commands = await runner.commands
    checks.equal(commands.count, 3, "metadata is collected with three batched Git processes")
    checks.expect(
        commands.allSatisfy { !$0.contains(where: { $0.hasSuffix("a.md") }) },
        "collector never invokes Git per file"
    )
    checks.equal(
        stubSnapshot.files[fakeRoot.appendingPathComponent("docs/a.md")]?.changes?.additions,
        2,
        "batched diff maps paths under browser root"
    )
    checks.expect(
        stubSnapshot.files[fakeRoot.appendingPathComponent("docs/new.md")]?.changes?.isUntracked == true,
        "batched status maps untracked paths"
    )
    checks.equal(
        Int(
            stubSnapshot.files[fakeRoot.appendingPathComponent("docs/a.md")]?
                .lastEditedAt?.timeIntervalSince1970 ?? 0
        ),
        1_721_000_000,
        "batched history maps timestamps"
    )

    let fileManager = FileManager.default
    let repositoryRoot = URL(fileURLWithPath: ".build/test-fixtures/git-metadata", isDirectory: true)
        .standardizedFileURL
    let root = repositoryRoot.appendingPathComponent("docs", isDirectory: true)
    do {
        try? fileManager.removeItem(at: repositoryRoot)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: repositoryRoot)
        try runGit(["config", "user.name", "Mindle Tests"], at: repositoryRoot)
        try runGit(["config", "user.email", "tests@mindle.local"], at: repositoryRoot)
        let tracked = root.appendingPathComponent("tracked.md")
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)
        try runGit(["add", "docs/tracked.md"], at: repositoryRoot)
        try runGit(
            ["commit", "-q", "-m", "fixture"],
            at: repositoryRoot,
            environment: [
                "GIT_AUTHOR_DATE": "2024-01-02T03:04:05Z",
                "GIT_COMMITTER_DATE": "2024-01-02T03:04:05Z"
            ]
        )
        try "one\ntwo\n".write(to: tracked, atomically: true, encoding: .utf8)
        let untracked = root.appendingPathComponent("new.txt")
        try "new\n".write(to: untracked, atomically: true, encoding: .utf8)

        var snapshot = GitMetadataSnapshot.empty
        for _ in 0..<5 {
            snapshot = await GitMetadataCollector.collect(for: root)
        }
        checks.equal(
            snapshot.files[tracked]?.changes?.additions,
            1,
            "working tree changes collected repeatedly without process hangs"
        )
        checks.expect(
            snapshot.files[untracked]?.changes?.isUntracked == true,
            "untracked file collected"
        )
        checks.equal(
            Int(snapshot.files[tracked]?.lastEditedAt?.timeIntervalSince1970 ?? 0),
            1_704_164_645,
            "last commit timestamp collected"
        )
    } catch {
        checks.expect(false, "Git integration fixture failed: \(error)")
    }
    try? fileManager.removeItem(at: repositoryRoot)

    print("GitFileMetadata: \(checks.passed) passed, \(checks.failures) failed")
    return checks.failures
}

private actor StubGitRunner {
    private(set) var commands: [[String]] = []

    func run(_ arguments: [String]) -> GitCommandResult {
        commands.append(arguments)
        if arguments.contains("--numstat") {
            return GitCommandResult(status: 0, output: Data("2\t1\tdocs/a.md\u{0}".utf8))
        }
        if arguments.contains("ls-files") {
            return GitCommandResult(status: 0, output: Data("docs/new.md\u{0}".utf8))
        }
        return GitCommandResult(
            status: 0,
            output: Data("\u{1e}1721000000\u{0}\u{0}\ndocs/a.md\u{0}".utf8)
        )
    }
}

private func runGit(
    _ arguments: [String],
    at directory: URL,
    environment: [String: String] = [:]
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "GitFileMetadataChecks",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
        )
    }
}
