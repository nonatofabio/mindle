import Foundation

@MainActor
func runFileBrowserStateChecks() async -> Int {
    let checks = Checks("FileBrowserState")
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("mindle-browser-state-\(UUID().uuidString)", isDirectory: true)

    do {
        let chapter = root.appendingPathComponent("Chapter", isDirectory: true)
        try fileManager.createDirectory(at: chapter, withIntermediateDirectories: true)
        let readme = root.appendingPathComponent("README.md")
        let nested = chapter.appendingPathComponent("notes.txt")
        try "# Read me".write(to: readme, atomically: true, encoding: .utf8)
        try "Notes".write(to: nested, atomically: true, encoding: .utf8)

        let browser = FileBrowserState()
        browser.setRoot(root)
        checks.expect(
            await waitUntil { !browser.isLoading },
            "local tree load completes"
        )
        checks.equal(browser.rootURL, root.standardizedFileURL, "root normalized")
        checks.equal(browser.rootDisplayName, root.lastPathComponent, "root display name")
        checks.equal(
            browser.rows.map(\.name),
            ["Chapter", "notes.txt", "README.md"],
            "local rows published"
        )

        browser.setSelectedURL(readme.appendingPathComponent("..").appendingPathComponent("README.md"))
        checks.equal(browser.selectedURL, readme.standardizedFileURL, "selection normalized")

        browser.toggleDirectory(chapter)
        checks.equal(browser.rows.map(\.name), ["Chapter", "README.md"], "directory collapses")
        checks.expect(browser.rows[0].isExpanded == false, "collapsed row state published")
        browser.toggleDirectory(chapter)
        checks.equal(browser.rows.count, 3, "directory expands")

        let firstProfile = SSHProfile(
            name: "First",
            hostname: "first",
            rootPath: "/workspace",
            favorite: false
        )!
        let secondProfile = SSHProfile(
            name: "Second",
            hostname: "second",
            rootPath: "/docs",
            favorite: true
        )!
        let staleGeneration = browser.beginRemoteLoad(profile: firstProfile)
        let currentGeneration = browser.beginRemoteLoad(profile: secondProfile)
        checks.expect(
            !browser.finishRemoteLoad(
                profile: firstProfile,
                listing: RemoteDocumentListing(
                    root: firstProfile.rootTarget,
                    files: [SSHTarget(userHostPath: "first:/workspace/old.md")!]
                ),
                generation: staleGeneration
            ),
            "stale remote result rejected"
        )
        checks.expect(
            browser.finishRemoteLoad(
                profile: secondProfile,
                listing: RemoteDocumentListing(
                    root: SSHTarget(userHostPath: "second:/Users/test")!,
                    files: [SSHTarget(userHostPath: "second:/Users/test/current.md")!]
                ),
                generation: currentGeneration
            ),
            "current remote result accepted"
        )
        checks.equal(browser.rootDisplayName, "Second", "remote profile name displayed")
        checks.equal(
            SSHTarget(sourceURL: browser.rootURL!)?.remotePath,
            "/Users/test",
            "effective fallback root published"
        )
        checks.equal(browser.rows.map(\.name), ["current.md"], "remote rows published")

        let failureGeneration = browser.beginRemoteLoad(profile: firstProfile)
        checks.expect(
            browser.failRemoteLoad(
                profile: firstProfile,
                message: "Connection failed",
                generation: failureGeneration
            ),
            "current remote failure accepted"
        )
        checks.equal(browser.errorMessage, "Connection failed", "remote error published")
        checks.expect(!browser.isLoading, "remote failure clears loading")

        _ = browser.beginRemoteLoad(profile: secondProfile)
        browser.cancelAll()
        checks.expect(!browser.isLoading, "cancel clears loading")

        browser.setRoot(nil)
        checks.equal(browser.rootURL, nil, "nil root clears root")
        checks.equal(browser.rows, [], "nil root clears rows")
    } catch {
        checks.expect(false, "fixture setup failed: \(error)")
    }

    let suiteName = "mindle-browser-settings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    checks.expect(BrowserDisplaySettings.showGitChanges(defaults: defaults), "Git changes default on")
    checks.expect(BrowserDisplaySettings.showLastEdited(defaults: defaults), "last edited default on")
    checks.expect(BrowserDisplaySettings.highlightActiveFile(defaults: defaults), "active highlight default on")
    defaults.set(false, forKey: BrowserDisplaySettings.showGitChangesKey)
    checks.expect(!BrowserDisplaySettings.showGitChanges(defaults: defaults), "Git changes can be disabled")

    try? fileManager.removeItem(at: root)
    print("FileBrowserState: \(checks.passed) passed, \(checks.failures) failed")
    return checks.failures
}

@MainActor
private func waitUntil(
    attempts: Int = 200,
    condition: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
