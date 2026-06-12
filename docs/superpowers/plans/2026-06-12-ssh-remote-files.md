# SSH Remote Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Mindle open, edit, and save Markdown/PDF files that live on a remote host reached over SSH, via an *Open Remote…* dialog, a `mindle://ssh` URL scheme, and the MCP `open_file` tool.

**Architecture:** Fetch-to-local-proxy. On open, `scp` the remote file down to a deterministic local cache path (`~/Library/Application Support/Mindle/ssh-cache/<hash>/<basename>`) and run the *existing* pipeline on that proxy. SSH appears only at three edges — open / save / reload — in one new `SSHTransport` module that shells out to the system `ssh`/`scp` binaries with `BatchMode=yes`. The remote identity rides the existing `DocumentTab.sourceURL` channel as a `mindle://ssh/<user@host>/<path>` URL, so tab title and open-dedup reuse machinery that already ships. The local proxy is a plain file, so annotations, editing, diff-review, and the sidecar all work unchanged.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit (macOS 14+), `Foundation.Process`, system `ssh`/`scp`. New XCTest target for the pure logic.

**Spec:** `docs/superpowers/specs/2026-06-12-ssh-remote-files-design.md`

---

## File Structure

**Create:**
- `Sources/mindle/SSHTarget.swift` — value type for `[user@]host:/path`; parsing (from dialog string and from `mindle://ssh` URL), canonical form, hash, proxy-path derivation. No SwiftUI/AppKit/`@MainActor`.
- `Sources/mindle/SSHTransport.swift` — `ProcessRunner` protocol + `SystemProcessRunner`, pure argv builders, `fetch`/`push`. No SwiftUI.
- `Sources/mindle/OpenRemoteSheet.swift` — the *Open Remote…* SwiftUI sheet.
- `Tests/mindleTests/SSHTargetTests.swift` — parsing / proxy-path / round-trip tests.
- `Tests/mindleTests/SSHTransportTests.swift` — argv + shell-quote + fake-runner tests.

**Modify:**
- `Package.swift` — add the `mindleTests` test target.
- `Sources/mindle/DocumentStore.swift` — `ssh-cache` dir helper; `openRemote`; factor `finishOpen`; remote save push-back in `commitEdit`; remote `reload`; watcher suppression for remote tabs.
- `Sources/mindle/MindleApp.swift` — route `mindle://ssh` URLs; `openFileRemote` for MCP; menu wiring point.
- `Sources/mindle/ContentView.swift` — *Open Remote…* menu command + sheet host + remote tab badge/status (the exact host view is discovered during Task 5; ContentView is the documented entry).
- `Sources/mindle/MCPServer.swift` — `open_file` accepts a remote target.
- `Sources/MindleMCP/main.swift` — `open_file` tool doc mentions remote form; pass through.
- `build.sh` — register `CFBundleURLTypes` for the `mindle` scheme.

---

## Task 1: `SSHTarget` value type + test target

**Files:**
- Create: `Sources/mindle/SSHTarget.swift`
- Create: `Tests/mindleTests/SSHTargetTests.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Add the test target to `Package.swift`**

Replace the whole `targets:` array so a test target exists:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mindle",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mindle",
            path: "Sources/mindle"
        ),
        .testTarget(
            name: "mindleTests",
            dependencies: ["mindle"],
            path: "Tests/mindleTests"
        )
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/mindleTests/SSHTargetTests.swift`:

```swift
import XCTest
@testable import mindle

final class SSHTargetTests: XCTestCase {
    func testParsesUserHostPath() {
        let t = SSHTarget(userHostPath: "fabio@devbox:/home/fabio/spec.md")
        XCTAssertEqual(t?.userHost, "fabio@devbox")
        XCTAssertEqual(t?.remotePath, "/home/fabio/spec.md")
        XCTAssertEqual(t?.basename, "spec.md")
        XCTAssertEqual(t?.canonical, "fabio@devbox:/home/fabio/spec.md")
    }

    func testParsesBareAliasPath() {
        let t = SSHTarget(userHostPath: "devbox:/srv/notes/readme.md")
        XCTAssertEqual(t?.userHost, "devbox")
        XCTAssertEqual(t?.remotePath, "/srv/notes/readme.md")
    }

    func testRejectsRelativePathAndMissingColon() {
        XCTAssertNil(SSHTarget(userHostPath: "devbox:relative/path.md"))
        XCTAssertNil(SSHTarget(userHostPath: "no-colon-here"))
        XCTAssertNil(SSHTarget(userHostPath: ":/empty/host.md"))
        XCTAssertNil(SSHTarget(userHostPath: "   "))
    }

    func testSourceURLRoundTrips() {
        let t = SSHTarget(userHostPath: "fabio@devbox:/home/fabio/my notes.md")!
        let url = t.sourceURL!
        XCTAssertEqual(url.scheme, "mindle")
        XCTAssertEqual(url.host, "ssh")
        let back = SSHTarget(sourceURL: url)
        XCTAssertEqual(back, t)
    }

    func testProxyURLIsDeterministicAndHashKeyed() {
        let dir = URL(fileURLWithPath: "/tmp/ssh-cache", isDirectory: true)
        let a = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
        let b = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
        let c = SSHTarget(userHostPath: "fabio@other:/a/spec.md")!
        XCTAssertEqual(a.proxyURL(cacheDir: dir), b.proxyURL(cacheDir: dir))
        XCTAssertNotEqual(a.proxyURL(cacheDir: dir), c.proxyURL(cacheDir: dir))
        XCTAssertEqual(a.proxyURL(cacheDir: dir).lastPathComponent, "spec.md")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails to build**

Run: `swift test --filter SSHTargetTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SSHTarget' in scope`.

- [ ] **Step 4: Implement `SSHTarget`**

Create `Sources/mindle/SSHTarget.swift`:

```swift
import Foundation

/// A remote file reachable over SSH: `[user@]host:/path`. `host` may be a
/// literal hostname or a `~/.ssh/config` alias. The remote path is always
/// absolute. This is a pure value type — no AppKit, no actor isolation — so
/// the parsing and path-derivation logic is unit-testable in isolation.
struct SSHTarget: Equatable {
    /// `fabio@devbox` or a bare alias like `devbox`.
    let userHost: String
    /// Absolute remote path, e.g. `/home/fabio/spec.md`.
    let remotePath: String

    /// Canonical `user@host:/path`. Stable identity for hashing, recents,
    /// and the `mindle://ssh` round-trip.
    var canonical: String { "\(userHost):\(remotePath)" }

    /// Remote file basename — used for the proxy filename and tab title.
    var basename: String { (remotePath as NSString).lastPathComponent }

    /// `mindle://ssh/<user@host>/<remotePath>` — the URL stored as a tab's
    /// `sourceURL` so the existing cache-backed-tab title/dedup logic works.
    var sourceURL: URL? {
        var comps = URLComponents()
        comps.scheme = "mindle"
        comps.host = "ssh"
        comps.path = "/\(userHost)\(remotePath)"   // remotePath already has a leading "/"
        return comps.url
    }

    /// Deterministic local proxy: `<cacheDir>/<hash>/<basename>`.
    func proxyURL(cacheDir: URL) -> URL {
        cacheDir.appendingPathComponent(Self.fnv1a(canonical), isDirectory: true)
                .appendingPathComponent(basename)
    }

    // MARK: Parsing

    /// Parse a `[user@]host:/path` string (the Open Remote… dialog form).
    /// Splits on the FIRST colon; requires a non-empty host and an absolute
    /// remote path. Returns nil for relative paths or missing components.
    init?(userHostPath input: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let uh = String(s[..<colon])
        let rp = String(s[s.index(after: colon)...])
        guard !uh.isEmpty, rp.hasPrefix("/") else { return nil }
        self.userHost = uh
        self.remotePath = rp
    }

    /// Parse a `mindle://ssh/<user@host>/<path>` URL. `url.path` is already
    /// percent-decoded by Foundation.
    init?(sourceURL url: URL) {
        guard url.scheme == "mindle", url.host == "ssh" else { return nil }
        let full = url.path
        let trimmed = full.hasPrefix("/") ? String(full.dropFirst()) : full
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let uh = String(trimmed[..<slash])
        let rp = String(trimmed[slash...])   // keeps the leading "/"
        guard !uh.isEmpty, rp.count > 1 else { return nil }
        self.userHost = uh
        self.remotePath = rp
    }

    private init(userHost: String, remotePath: String) {
        self.userHost = userHost
        self.remotePath = remotePath
    }

    /// FNV-1a 64-bit hash, hex — same family as DocumentStore's content/url
    /// hashes. Kept local so this type stays dependency-free.
    static func fnv1a(_ text: String) -> String {
        var h: UInt64 = 14695981039346656037
        for byte in text.utf8 { h ^= UInt64(byte); h = h &* 1099511628211 }
        return String(format: "%016llx", h)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SSHTargetTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/mindle/SSHTarget.swift Tests/mindleTests/SSHTargetTests.swift
git commit -m "Add SSHTarget value type + test target (rc5)"
```

---

## Task 2: `SSHTransport` — argv builders, shell-quoting, fetch/push

**Files:**
- Create: `Sources/mindle/SSHTransport.swift`
- Create: `Tests/mindleTests/SSHTransportTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/mindleTests/SSHTransportTests.swift`:

```swift
import XCTest
@testable import mindle

final class SSHTransportTests: XCTestCase {
    func testFetchArgsCarryBatchModeAndConnectTimeout() {
        let t = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
        let tmp = URL(fileURLWithPath: "/tmp/x/spec.md.fetch")
        let args = SSHTransport.fetchArgs(t, tmp: tmp)
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=10"))
        // scp remote source is single-quoted user@host:'/path', local last.
        XCTAssertEqual(args.last, tmp.path)
        XCTAssertTrue(args.contains("fabio@devbox:'/a/spec.md'"))
    }

    func testPushArgsUploadToRemoteTemp() {
        let t = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
        let proxy = URL(fileURLWithPath: "/tmp/x/spec.md")
        let args = SSHTransport.pushArgs(proxy, to: t)
        XCTAssertEqual(args.first.map { $0 }, proxy.path)   // local source first
        XCTAssertTrue(args.contains("fabio@devbox:'/a/spec.md.mindle-tmp'"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
    }

    func testRemoteMvArgsAreQuoted() {
        let t = SSHTarget(userHostPath: "fabio@devbox:/a/my notes.md")!
        let args = SSHTransport.remoteMvArgs(t)
        // ssh fabio@devbox mv '/a/my notes.md.mindle-tmp' '/a/my notes.md'
        XCTAssertEqual(args.first, "fabio@devbox")
        XCTAssertTrue(args.contains("mv '/a/my notes.md.mindle-tmp' '/a/my notes.md'"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
    }

    func testShellSingleQuoteEscapesEmbeddedQuotes() {
        XCTAssertEqual(SSHTransport.shellSingleQuote("/a/b"), "'/a/b'")
        XCTAssertEqual(SSHTransport.shellSingleQuote("it's"), "'it'\\''s'")
    }

    func testFetchThrowsOnNonZeroExit() async {
        let runner = FakeRunner(result: ProcessResult(status: 1, stdout: Data(),
                                stderr: "ssh: connect to host devbox port 22: Connection refused\n".data(using: .utf8)!))
        let t = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
        let proxy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spec.md")
        do {
            try await SSHTransport.fetch(t, to: proxy, runner: runner)
            XCTFail("expected throw")
        } catch let SSHTransportError.nonZeroExit(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("Connection refused"))
        } catch { XCTFail("wrong error: \(error)") }
    }
}

private struct FakeRunner: ProcessRunner {
    let result: ProcessResult
    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult { result }
}
```

- [ ] **Step 2: Run the test to verify it fails to build**

Run: `swift test --filter SSHTransportTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SSHTransport' in scope`.

- [ ] **Step 3: Implement `SSHTransport`**

Create `Sources/mindle/SSHTransport.swift`:

```swift
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

    /// `scp <flags> user@host:'/remote/path' <localTmp>`
    static func fetchArgs(_ target: SSHTarget, tmp: URL) -> [String] {
        sshFlags + ["\(target.userHost):\(shellSingleQuote(target.remotePath))", tmp.path]
    }

    /// `scp <flags> <localProxy> user@host:'/remote/path.mindle-tmp'`
    static func pushArgs(_ proxy: URL, to target: SSHTarget) -> [String] {
        let remoteTmp = target.remotePath + remoteTmpSuffix
        return [proxy.path] + sshFlags + ["\(target.userHost):\(shellSingleQuote(remoteTmp))"]
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SSHTransportTests 2>&1 | tail -25`
Expected: PASS (5 tests). If `testFetchArgs` fails on quoting, confirm the expected string includes the single quotes around the remote path.

- [ ] **Step 5: Commit**

```bash
git add Sources/mindle/SSHTransport.swift Tests/mindleTests/SSHTransportTests.swift
git commit -m "Add SSHTransport: scp fetch/push with atomic moves (rc5)"
```

---

## Task 3: Remote open — `ssh-cache` dir, `finishOpen` refactor, `openRemote`, watcher suppression

**Files:**
- Modify: `Sources/mindle/DocumentStore.swift` (open path ~488-549; watcher ~575-601, ~624-639)

> Integration task: AppKit/`@MainActor` code. Verified by `swift build` + the manual checklist in Task 8, not by unit tests.

- [ ] **Step 1: Add the `ssh-cache` directory helper**

After `clipboardSidecarsDir()` (ends at `DocumentStore.swift:445`), add:

```swift
    /// ~/Library/Application Support/Mindle/ssh-cache/. Holds per-target
    /// proxy copies of remote files (`<hash>/<basename>`) plus their local
    /// sidecars. Created on first access.
    static func sshCacheDir() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support
            .appendingPathComponent("Mindle", isDirectory: true)
            .appendingPathComponent("ssh-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
```

- [ ] **Step 2: Add a stored property to track the active tab's remote target**

After `@Published var fileURL: URL?` (`DocumentStore.swift:216`), add:

```swift
    /// Set when the active tab is a remote SSH file. Drives save push-back,
    /// reload re-fetch, and watcher suppression. Nil for local/URL/clipboard
    /// tabs. Kept in sync with the active tab's `sourceURL` in `finishOpen`.
    private var activeRemoteTarget: SSHTarget?
```

- [ ] **Step 3: Factor `finishOpen` out of `open(url:)`**

Replace the body of `open(url:)` (`DocumentStore.swift:488-549`) with this — the read stays synchronous; the tab-construction body moves into `finishOpen`:

```swift
    func open(url: URL) {
        // Already open in this window? Switch to its tab without re-reading.
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            activate(tabID: existing.id)
            return
        }
        do {
            let kind = DocumentKind.kind(for: url)
            let text: String = (kind == .pdf) ? "" : try String(contentsOf: url, encoding: .utf8)
            finishOpen(url: url, text: text, kind: kind, sourceURL: nil, remoteTarget: nil)
        } catch {
            NSSound.beep()
        }
    }

    /// Shared tab-construction body for both local `open(url:)` and remote
    /// `openRemote`. `url` is always a local file URL (the proxy, for remote
    /// tabs). `sourceURL`/`remoteTarget` are set only for remote tabs.
    private func finishOpen(url: URL, text: String, kind: DocumentKind,
                            sourceURL: URL?, remoteTarget: SSHTarget?) {
        let shouldRebuildTree: Bool
        if let root = fileTree?.url {
            shouldRebuildTree = !Self.isDescendant(url: url, of: root)
        } else {
            shouldRebuildTree = true
        }

        snapshotActiveTab()

        var newTab = DocumentTab(id: UUID(), fileURL: url, rawText: text,
                                 annotations: [], lastSyncedText: text)
        newTab.sourceURL = sourceURL
        tabs.append(newTab)
        activeTabID = newTab.id

        closeSearch()
        focusedAnnotation = nil
        editingAnnotationID = nil
        updateSelection(text: "", prefix: "", suffix: "")

        self.fileURL = url
        self.rawText = text
        self.lastSyncedText = text
        self.annotations = []
        self.collaborators = [:]
        self.activeRemoteTarget = remoteTarget
        self.resetReaderPrefsToUserDefaults()
        self.loadSidecar()

        snapshotActiveTab()

        if shouldRebuildTree { refreshFileTree() }
        if url.isFileURL && remoteTarget == nil {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        updateWatcher()
        syncInactiveWatchers()
    }
```

- [ ] **Step 4: Sync `activeRemoteTarget` on tab switch**

`activeRemoteTarget` must follow the active tab. Find `activate(tabID:)` (search `func activate(tabID`) and, where it sets `self.fileURL` from the activated tab, also set:

```swift
        self.activeRemoteTarget = tab.sourceURL.flatMap { SSHTarget(sourceURL: $0) }
```

(Use the activated tab's variable name in scope — it is the tab whose `fileURL` is being assigned to `self.fileURL`.)

- [ ] **Step 5: Add `openRemote`**

Add after `open(url:)`:

```swift
    /// Open a remote SSH file: fetch it to the local proxy, then run the
    /// normal pipeline on that proxy. Dedups on the canonical target across
    /// already-open tabs. Surfaces failures via an alert; creates no tab on
    /// failure.
    func openRemote(_ target: SSHTarget) async {
        guard let cacheDir = Self.sshCacheDir(), let source = target.sourceURL else {
            NSSound.beep(); return
        }
        // Dedup on the remote identity (sourceURL), before fetching.
        if let existing = tabs.first(where: { $0.sourceURL == source }) {
            activate(tabID: existing.id); return
        }
        let proxy = target.proxyURL(cacheDir: cacheDir)
        do {
            try await SSHTransport.fetch(target, to: proxy)
            let kind = DocumentKind.kind(for: proxy)
            let text: String = (kind == .pdf) ? "" : try String(contentsOf: proxy, encoding: .utf8)
            finishOpen(url: proxy, text: text, kind: kind, sourceURL: source, remoteTarget: target)
        } catch {
            presentRemoteError(title: "Couldn’t open \(target.canonical)", error: error)
        }
    }

    /// Shared alert for remote transport failures.
    func presentRemoteError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
```

- [ ] **Step 6: Suppress the body watcher for remote tabs**

In `updateWatcher()` (`DocumentStore.swift:575`), the body watcher must not run on a remote proxy (it would only fire on our own writes). Change the body-watcher guard from:

```swift
        if DocumentKind.kind(for: url) != .pdf {
```
to:
```swift
        if DocumentKind.kind(for: url) != .pdf && activeRemoteTarget == nil {
```

In `syncInactiveWatchers()` (`DocumentStore.swift:624`), inside the `for tab in tabs` loop, skip the inactive body watcher for remote tabs by changing:

```swift
            if inactiveFileWatchers[id] == nil,
               DocumentKind.kind(for: url) != .pdf {
```
to:
```swift
            if inactiveFileWatchers[id] == nil,
               DocumentKind.kind(for: url) != .pdf,
               tab.sourceURL == nil {
```

(The sidecar watcher branch is left untouched — a local MCP agent writing the proxy's sidecar should still be picked up.)

- [ ] **Step 7: Build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds. (No unit test — exercised in Task 8.)

- [ ] **Step 8: Commit**

```bash
git add Sources/mindle/DocumentStore.swift
git commit -m "DocumentStore: openRemote + finishOpen refactor + remote watcher suppression (rc5)"
```

---

## Task 4: Remote save (push-back) + remote reload (↻)

**Files:**
- Modify: `Sources/mindle/DocumentStore.swift` (`commitEdit` ~1160-1193; add `reloadRemote`)

> Integration task: verified by build + Task 8 manual checklist.

- [ ] **Step 1: Push to the remote after a successful local save**

In `commitEdit(draft:)` (`DocumentStore.swift:1160`), the happy path writes the proxy locally then updates state. After the local write succeeds and state is updated (after `editingBlock = nil` at line 1192), add a push when the tab is remote. Replace the tail of the function (from the `do { try draft.write… }` block through `editingBlock = nil`) with:

```swift
        do {
            try draft.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DebugConsole.shared.log("EDIT save failed: \(error)")
            NSSound.beep()
            return
        }
        rawText = draft
        lastSyncedText = draft
        snapshotActiveTab()
        editingBlock = nil

        // Remote tab: push the just-saved proxy back over SSH. The local
        // edit is already safe in the proxy; on failure we keep it and let
        // the user retry rather than losing work.
        if let target = activeRemoteTarget {
            let proxy = url
            Task { @MainActor in
                do {
                    try await SSHTransport.push(proxy, to: target)
                } catch {
                    presentRemoteError(title: "Saved locally, but couldn’t push to \(target.canonical)", error: error)
                }
            }
        }
```

- [ ] **Step 2: Add `reloadRemote`**

Add near `reloadFromDisk()` (`DocumentStore.swift:557`):

```swift
    /// Manual ↻ for a remote tab: re-fetch the proxy, then run the same
    /// reload path as a local watcher event so diff-on-reload kicks in when
    /// the remote file changed underneath us.
    func reloadRemote() async {
        guard let target = activeRemoteTarget, let url = fileURL else { return }
        do {
            try await SSHTransport.fetch(target, to: url)
            reloadFromDisk()
        } catch {
            presentRemoteError(title: "Couldn’t refresh \(target.canonical)", error: error)
        }
    }
```

(`reloadFromDisk()` already re-reads `fileURL`, compares to `rawText`, and short-circuits when unchanged — exactly the diff baseline behaviour we want.)

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/mindle/DocumentStore.swift
git commit -m "DocumentStore: remote save push-back + manual remote reload (rc5)"
```

---

## Task 5: UI — Open Remote… sheet, menu command, remote tab affordances

**Files:**
- Create: `Sources/mindle/OpenRemoteSheet.swift`
- Modify: `Sources/mindle/ContentView.swift` (menu command + sheet host + tab badge/↻)

> Integration task: SwiftUI. Verified by build + Task 8 manual checklist. ContentView's exact view hierarchy is discovered while implementing; the steps below give the required pieces and where they attach.

- [ ] **Step 1: Build the Open Remote… sheet**

Create `Sources/mindle/OpenRemoteSheet.swift`:

```swift
import SwiftUI

/// Modal sheet for opening a remote SSH file. Validates `[user@]host:/path`
/// live; recents are persisted as canonical target strings in UserDefaults.
struct OpenRemoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onOpen: (SSHTarget) -> Void

    @State private var input: String = ""
    @AppStorage("mindle.remoteRecents") private var recentsRaw: String = ""

    private var recents: [String] {
        recentsRaw.split(separator: "\n").map(String.init)
    }
    private var parsed: SSHTarget? { SSHTarget(userHostPath: input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Remote File").font(.headline)
            Text("Enter an SSH target. Uses your existing SSH config and keys.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("user@host:/path/to/file.md", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if parsed != nil { open() } }

            if !recents.isEmpty {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(recents, id: \.self) { r in
                    Button(r) { input = r }
                        .buttonStyle(.link).font(.callout)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func open() {
        guard let target = parsed else { return }
        var list = recents.filter { $0 != target.canonical }
        list.insert(target.canonical, at: 0)
        recentsRaw = list.prefix(8).joined(separator: "\n")
        onOpen(target)
        dismiss()
    }
}
```

- [ ] **Step 2: Host the sheet + menu command in ContentView**

In `ContentView.swift`, add state on the main content view:

```swift
    @State private var showOpenRemote = false
```

Attach the sheet to the top-level content view (alongside existing `.sheet`/modifiers):

```swift
        .sheet(isPresented: $showOpenRemote) {
            OpenRemoteSheet { target in
                Task { await store.openRemote(target) }
            }
        }
```

Add a File-menu command. Find the existing `CommandGroup` for file open (search `Open…` or `CommandGroup(replacing: .newItem`/`after:`). Add, next to the existing Open command:

```swift
            Button("Open Remote…") { showOpenRemote = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
```

If commands live in `MindleApp`'s `.commands { }` rather than ContentView, post a notification or use a shared `@FocusedValue`/`store` flag instead; follow the pattern already used for the existing Open command. The required behaviour: the menu item flips `showOpenRemote = true` on the active window's store/view.

- [ ] **Step 3: Remote tab affordances (badge + ↻)**

Where the tab title is rendered (search the TabBar / tab label view that uses `tab.sourceURL` for the title today — `sourceURL` already drives URL-PDF titles), show a small SF Symbol when the tab is remote:

```swift
            if let s = tab.sourceURL, s.scheme == "mindle", s.host == "ssh" {
                Image(systemName: "network")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(SSHTarget(sourceURL: s)?.canonical ?? "Remote file")
            }
```

Add a ↻ Reload control visible only for the active remote tab (in the same toolbar/area as other per-document controls):

```swift
            if store.fileURL != nil, let s = store.tabs.first(where: { $0.id == store.activeTabID })?.sourceURL,
               s.scheme == "mindle", s.host == "ssh" {
                Button { Task { await store.reloadRemote() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Re-fetch this file from the remote host")
            }
        }
```

(Exact placement follows the existing toolbar/tab structure — match the surrounding controls.)

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/mindle/OpenRemoteSheet.swift Sources/mindle/ContentView.swift
git commit -m "UI: Open Remote… sheet, menu command, remote tab badge + reload (rc5)"
```

---

## Task 6: `mindle://ssh` URL scheme — registration + routing

**Files:**
- Modify: `build.sh` (Info.plist, after line 243)
- Modify: `Sources/mindle/MindleApp.swift` (`application(_:open:)` ~218)

- [ ] **Step 1: Register the URL scheme in the app Info.plist**

In `build.sh`, inside the app `Info.plist` heredoc, after the `SUPublicEDKey` block (after line 243, before `CFBundleDocumentTypes`), add:

```
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.mindle.ssh</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>mindle</string>
      </array>
    </dict>
  </array>
```

- [ ] **Step 2: Route `mindle://ssh` URLs to `openRemote`**

In `MindleApp.swift`, replace `application(_:open:)` (lines 218-229) so SSH URLs go to the remote path and everything else keeps the existing behaviour:

```swift
    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls {
            if let target = SSHTarget(sourceURL: url) {
                routeRemoteOpen(target)
            } else if let store = activeStore {
                store.open(url: url)
            } else {
                pendingURLs.append(url)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hand a remote target to the active store, or buffer it (as its
    /// `mindle://ssh` URL) for replay into the first window on cold launch.
    private func routeRemoteOpen(_ target: SSHTarget) {
        if let store = activeStore {
            Task { await store.openRemote(target) }
        } else if let url = target.sourceURL {
            pendingURLs.append(url)
        }
    }
```

- [ ] **Step 3: Replay buffered SSH URLs on first window**

In `register(store:)` (`MindleApp.swift:268`), the replay loop calls `store.open(first)`. Make it handle a buffered `mindle://ssh` URL. Replace the `if let first = queued.first { store.open(url: first) }` block with:

```swift
            if let first = queued.first {
                if let target = SSHTarget(sourceURL: first) {
                    Task { await store.openRemote(target) }
                } else {
                    store.open(url: first)
                }
            }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add build.sh Sources/mindle/MindleApp.swift
git commit -m "Register mindle:// URL scheme + route mindle://ssh to openRemote (rc5)"
```

---

## Task 7: MCP `open_file` — remote targets

**Files:**
- Modify: `Sources/mindle/MindleApp.swift` (add `openFileRemote`)
- Modify: `Sources/mindle/MCPServer.swift` (`open_file` case ~351-366)
- Modify: `Sources/MindleMCP/main.swift` (tool doc ~271-288; dispatch ~447-462)

- [ ] **Step 1: Add `openFileRemote` to AppDelegate**

In `MindleApp.swift`, after `openFile(path:focusApp:)` (ends line 262), add:

```swift
    /// MCP-side: open a remote SSH target in Mindle. Dedups across windows
    /// on the canonical target; otherwise opens in the most-recently-active
    /// store. Returns the canonical target on success, nil if no window.
    func openFileRemote(target: SSHTarget, focusApp: Bool) async -> (focused: Bool, canonical: String)? {
        registeredStores.removeAll { $0.store == nil }
        let source = target.sourceURL
        for ref in registeredStores {
            guard let s = ref.store else { continue }
            if let existing = s.tabs.first(where: { $0.sourceURL == source }) {
                s.activate(tabID: existing.id)
                if focusApp { NSApp.activate(ignoringOtherApps: true) }
                return (focused: true, canonical: target.canonical)
            }
        }
        guard let store = activeStore ?? registeredStores.first?.store else { return nil }
        await store.openRemote(target)
        if focusApp { NSApp.activate(ignoringOtherApps: true) }
        return (focused: false, canonical: target.canonical)
    }
```

- [ ] **Step 2: Accept a remote target in the `open_file` MCP op**

In `MCPServer.swift`, replace the `case "open_file":` block (lines 351-366) with one that detects a remote target — either a `mindle://ssh/...` URL or a `host:/path` string:

```swift
        case "open_file":
            guard let path = request["path"] as? String, !path.isEmpty else {
                return ["ok": false, "error": "missing 'path'"]
            }
            let focusApp = (request["focus_app"] as? Bool) ?? false
            // Remote target? Accept a mindle://ssh URL or a [user@]host:/path string.
            let remote: SSHTarget? = URL(string: path).flatMap { SSHTarget(sourceURL: $0) }
                ?? (path.contains(":/") && !path.hasPrefix("/") ? SSHTarget(userHostPath: path) : nil)
            if let target = remote {
                let result = await MainActor.run { Optional(target) }   // keep on main actor
                _ = result
                let opened = await AppDelegate.shared?.openFileRemote(target: target, focusApp: focusApp)
                guard let opened else {
                    return ["ok": false, "error": "no Mindle window is open to host '\(target.canonical)'"]
                }
                return ["ok": true, "focused": opened.focused, "path": opened.canonical]
            }
            let result = await MainActor.run {
                AppDelegate.shared?.openFile(path: path, focusApp: focusApp)
            }
            guard let result else {
                return ["ok": false, "error": "couldn't open: file not found at '\(path)' or no Mindle window is open"]
            }
            return ["ok": true, "focused": result.focused, "path": result.url.path]
```

> Note: `openFileRemote` is `@MainActor` (AppDelegate is `@MainActor`), so `await AppDelegate.shared?.openFileRemote(...)` already hops to the main actor — the `MainActor.run` placeholder line above can be dropped if the surrounding `dispatch` context makes the optional-chaining await compile cleanly. Keep the code minimal: call `await AppDelegate.shared?.openFileRemote(target:focusApp:)` directly.

Simplify to:

```swift
        case "open_file":
            guard let path = request["path"] as? String, !path.isEmpty else {
                return ["ok": false, "error": "missing 'path'"]
            }
            let focusApp = (request["focus_app"] as? Bool) ?? false
            let remote: SSHTarget? = URL(string: path).flatMap { SSHTarget(sourceURL: $0) }
                ?? (path.contains(":/") && !path.hasPrefix("/") ? SSHTarget(userHostPath: path) : nil)
            if let target = remote {
                guard let opened = await AppDelegate.shared?.openFileRemote(target: target, focusApp: focusApp) else {
                    return ["ok": false, "error": "no Mindle window is open to host '\(target.canonical)'"]
                }
                return ["ok": true, "focused": opened.focused, "path": opened.canonical]
            }
            let result = await MainActor.run {
                AppDelegate.shared?.openFile(path: path, focusApp: focusApp)
            }
            guard let result else {
                return ["ok": false, "error": "couldn't open: file not found at '\(path)' or no Mindle window is open"]
            }
            return ["ok": true, "focused": result.focused, "path": result.url.path]
```

- [ ] **Step 3: Document the remote form in the MCP tool schema**

In `Sources/MindleMCP/main.swift`, update the `open_file` `path` description (line 276-279) to mention the remote form:

```swift
                        "path": [
                            "type": "string",
                            "description": "A local absolute path, OR a remote SSH target as 'user@host:/path' (or a mindle://ssh/user@host/path URL). Remote files are fetched over the user's existing SSH config. Markdown (.md, .markdown, .txt) and text-based PDF are supported."
                        ],
```

Also extend the tool `description` (line 272) by appending: `" Accepts remote SSH targets (user@host:/path) as well as local paths."`. The dispatch case (lines 447-462) already forwards `path` verbatim, so no dispatch change is needed.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeds. If the `await AppDelegate.shared?.openFileRemote` optional-await doesn't compile in the `dispatch` context, bind first: `let delegate = await MainActor.run { AppDelegate.shared }` then `await delegate?.openFileRemote(...)`.

- [ ] **Step 5: Commit**

```bash
git add Sources/mindle/MindleApp.swift Sources/mindle/MCPServer.swift Sources/MindleMCP/main.swift
git commit -m "MCP open_file: accept remote SSH targets (rc5)"
```

---

## Task 8: Manual integration verification + release (rc5)

**Files:**
- Modify: `build.sh` (`SHORT_VERSION_FALLBACK`)
- Create: `docs/releases/v3.1.0-rc5.md`

- [ ] **Step 1: Full build + test gate**

```bash
swift test 2>&1 | tail -15      # SSHTarget + SSHTransport suites green
./build.sh 2>&1 | tail -20      # app bundle builds with the new Info.plist
```
Expected: tests pass; build produces `Mindle.app`. Confirm the scheme registered:
```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "<path-to>/Mindle.app/Contents/Info.plist"
```
Expected: shows the `mindle` scheme entry.

- [ ] **Step 2: Manual integration test against a real host**

Use a reachable host with key/agent auth (e.g. `cortana.local`). Run the built app and verify each:

1. **Open via dialog:** `File ▸ Open Remote…`, enter `user@host:/absolute/path.md` → renders; tab shows the `network` badge; title is the basename.
2. **Annotate:** add a highlight + note → confirm a sidecar appears at `~/Library/Application Support/Mindle/ssh-cache/<hash>/.<basename>.mindle.json`.
3. **Edit + save:** edit a block, Save → no error toast; on the host, `cat` the file and confirm the change landed (atomic temp→mv left no `.mindle-tmp`).
4. **Drift + reload:** change the file on the host (`echo >> …`), click ↻ → diff-on-reload banner appears with the change.
5. **Dedup:** Open Remote… the same target again → re-activates the tab, no second fetch.
6. **URL scheme:** `open 'mindle://ssh/user@host/absolute/path.md'` from Terminal → opens in Mindle.
7. **MCP:** via the MCP client, `open_file` with `path:"user@host:/absolute/path.md"` → tab opens; response `path` is the canonical target.
8. **Failure paths:** bad host (`user@nope.invalid:/x.md`) → clear "connect" alert, no tab; bad remote path → clear "No such file" alert; verify save-failure keeps the local edit and shows the retry alert (e.g. open a read-only remote file and try to save).

Record any failure and fix before release. (This step has no automated assertion — it is the acceptance gate for the AppKit/transport integration.)

- [ ] **Step 3: Bump the version fallback**

In `build.sh`, set `SHORT_VERSION_FALLBACK` to `3.1.0-rc5`.

- [ ] **Step 4: Write the release notes**

Create `docs/releases/v3.1.0-rc5.md` (match the voice/structure of `v3.1.0-rc4.md`): lead with opening remote files over SSH (dialog + `mindle://ssh` scheme + MCP), explain the fetch-to-proxy model and the key/agent (BatchMode) requirement, note manual-refresh + local sidecars and that shared remote sidecars/polling are deferred follow-ups. Close with the compare link `v3.1.0-rc4...v3.1.0-rc5` and the note that rc5 is intended as the last RC before the v3.1.0 stable bundle.

- [ ] **Step 5: Commit**

```bash
git add build.sh docs/releases/v3.1.0-rc5.md
git commit -m "Add v3.1.0-rc5 release notes + bump fallback"
```

- [ ] **Step 6: Tag/merge ritual (only after the branch is reviewed and green)**

Follow the established release ritual: `git pull --ff-only origin main` (pick up bot appcast commits), `git checkout main && git merge --ff-only <branch>`, `git push origin main`, `git tag v3.1.0-rc5`, `git push origin v3.1.0-rc5`, then delete the feature branch. CI builds the signed/notarized DMG and updates `docs/appcast.xml` on the beta channel.

---

## Self-Review

**Spec coverage:**
- Identity model / deterministic proxy → Task 1 (`proxyURL`) + Task 3 (`ssh-cache`, `finishOpen`). ✓
- Sidecar local & keyed by target → free via proxy being a local file; verified in Task 8 step 2. ✓ (no code task needed — confirmed during code reading)
- Watcher suppression → Task 3 step 6. ✓
- `SSHTransport` shell-out, BatchMode, atomic moves, no injection → Task 2. ✓
- Three touch-points (open/save/reload) → Task 3 (open), Task 4 (save, reload). ✓
- Open Remote… dialog + `mindle://ssh` scheme + remote affordances → Task 5, Task 6. ✓
- MCP `open_file` remote → Task 7. ✓
- Error handling (alerts, keep-dirty-on-save-fail, dedup) → Task 3/4/7 + Task 8 step 8. ✓
- Testing (unit for pure logic, manual integration) → Task 1/2 (unit), Task 8 (manual). ✓
- Release as rc5 → Task 8. ✓
- Out of scope (shared sidecars, polling) → not implemented, noted in release notes (Task 8 step 4). ✓

**Placeholder scan:** No "TBD"/"add error handling" placeholders; every code step shows code. Task 5/7 carry explicit "match the existing pattern / discovered during implementation" notes where the exact view/compile shape is environment-dependent — these are guidance, not missing content.

**Type consistency:** `SSHTarget(userHostPath:)`, `SSHTarget(sourceURL:)`, `proxyURL(cacheDir:)`, `canonical`, `basename`, `sourceURL` used identically across Tasks 1/3/5/6/7. `SSHTransport.fetch/push/fetchArgs/pushArgs/remoteMvArgs/shellSingleQuote`, `ProcessRunner.run(launchPath:arguments:)`, `ProcessResult`, `SSHTransportError` consistent across Tasks 2/3/4. `finishOpen(url:text:kind:sourceURL:remoteTarget:)`, `openRemote(_:)`, `reloadRemote()`, `openFileRemote(target:focusApp:)`, `activeRemoteTarget`, `presentRemoteError(title:error:)` consistent across Tasks 3/4/5/7. ✓
