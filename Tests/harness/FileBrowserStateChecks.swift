import Combine
import Foundation

@MainActor
func runFileBrowserStateChecks() async -> Int {
    let checks = Checks("FileBrowserState")
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: ".build/test-fixtures/browser-state", isDirectory: true)
        .standardizedFileURL

    do {
        try? fileManager.removeItem(at: root)
        let chapter = root.appendingPathComponent("Chapter", isDirectory: true)
        try fileManager.createDirectory(at: chapter, withIntermediateDirectories: true)
        let readme = root.appendingPathComponent("README.md")
        let nested = chapter.appendingPathComponent("notes.txt")
        try "# Read me".write(to: readme, atomically: true, encoding: .utf8)
        try "Notes".write(to: nested, atomically: true, encoding: .utf8)

        let browser = FileBrowserState(metadataBuilder: { _ in .empty })
        var rowPublications = 0
        let rowSubscription = browser.$rows.sink { _ in rowPublications += 1 }
        defer { rowSubscription.cancel() }

        browser.setRoot(root)
        checks.expect(await waitUntil { !browser.isLoading }, "local tree load completes")
        checks.equal(browser.rootURL, root, "root normalized")
        checks.equal(
            browser.rows.map(\.name),
            ["Chapter", "notes.txt", "README.md"],
            "local rows published"
        )

        let stableRows = browser.rows
        let publicationsAfterLoad = rowPublications
        browser.setSelectedURL(readme.appendingPathComponent("..").appendingPathComponent("README.md"))
        browser.setSelectedURL(nested)
        browser.setSelectedURL(readme)
        checks.equal(browser.selectedURL, readme, "selection normalized")
        checks.equal(browser.rows, stableRows, "selection changes do not mutate row identity or state")
        checks.equal(
            rowPublications,
            publicationsAfterLoad,
            "selection changes do not republish rows"
        )

        browser.toggleDirectory(chapter)
        checks.equal(browser.rows.map(\.name), ["Chapter", "README.md"], "directory collapses")
        checks.expect(!browser.rows[0].isExpanded, "collapsed row state published")
        let collapsedRows = browser.rows
        browser.setSelectedURL(readme)
        checks.equal(browser.rows, collapsedRows, "selection preserves collapsed state")

        let publicationsBeforeRefresh = rowPublications
        browser.refresh()
        checks.expect(await waitUntil { !browser.isLoading }, "refresh completes")
        checks.equal(browser.rows, collapsedRows, "refresh preserves externalized expansion state")
        checks.equal(
            rowPublications,
            publicationsBeforeRefresh,
            "equal refresh result does not republish rows"
        )

        browser.toggleDirectory(chapter)
        checks.equal(browser.rows.map(\.id), stableRows.map(\.id), "re-expansion restores stable row identities")
    } catch {
        checks.expect(false, "fixture setup failed: \(error)")
    }

    let slowRoot = URL(fileURLWithPath: ".build/test-fixtures/slow").standardizedFileURL
    let fastRoot = URL(fileURLWithPath: ".build/test-fixtures/fast").standardizedFileURL
    let staleMetadataURL = slowRoot.appendingPathComponent("stale.md")
    let currentMetadataURL = fastRoot.appendingPathComponent("current.md")
    let generationBrowser = FileBrowserState(
        treeBuilder: { url in
            if url == slowRoot {
                Thread.sleep(forTimeInterval: 0.18)
            }
            return syntheticTree(root: url, filename: url == slowRoot ? "stale.md" : "current.md")
        },
        metadataBuilder: { url in
            if url == slowRoot {
                try? await Task.sleep(nanoseconds: 220_000_000)
                return GitMetadataSnapshot(files: [
                    staleMetadataURL: GitFileMetadata(
                        changes: GitFileChanges(additions: 9, deletions: 9, isUntracked: false)
                    )
                ])
            }
            return GitMetadataSnapshot(files: [
                currentMetadataURL: GitFileMetadata(
                    changes: GitFileChanges(additions: 1, deletions: 0, isUntracked: false)
                )
            ])
        }
    )
    generationBrowser.setRoot(slowRoot)
    generationBrowser.setRoot(fastRoot)
    checks.expect(
        await waitUntil {
            !generationBrowser.isLoading
                && generationBrowser.rows.map(\.name) == ["current.md"]
                && generationBrowser.gitMetadata.files[currentMetadataURL] != nil
        },
        "new generation publishes tree and metadata"
    )
    try? await Task.sleep(nanoseconds: 300_000_000)
    checks.equal(generationBrowser.rootURL, fastRoot, "latest root remains active")
    checks.equal(generationBrowser.rows.map(\.name), ["current.md"], "stale tree result is rejected")
    checks.expect(
        generationBrowser.gitMetadata.files[staleMetadataURL] == nil,
        "stale metadata result is rejected"
    )

    generationBrowser.setRoot(slowRoot)
    generationBrowser.cancelAll()
    try? await Task.sleep(nanoseconds: 250_000_000)
    checks.expect(!generationBrowser.isLoading, "cancel clears loading state")
    checks.equal(generationBrowser.rows, [], "cancelled generation cannot publish rows")

    generationBrowser.setRoot(nil)
    checks.equal(generationBrowser.rootURL, nil, "nil root clears root")
    checks.equal(generationBrowser.rows, [], "nil root clears rows")

    try? fileManager.removeItem(at: root)
    print("FileBrowserState: \(checks.passed) passed, \(checks.failures) failed")
    return checks.failures
}

private func syntheticTree(root: URL, filename: String) -> FileNode {
    let file = root.appendingPathComponent(filename).standardizedFileURL
    return FileNode(
        url: root,
        name: root.lastPathComponent,
        isDirectory: true,
        children: [
            FileNode(
                url: file,
                name: filename,
                isDirectory: false,
                children: nil
            )
        ]
    )
}

@MainActor
private func waitUntil(
    attempts: Int = 300,
    condition: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
