import Foundation

func runSSHTransportChecks() async -> Int {
    let c = Checks("SSHTransport")

    // fetchArgs carry BatchMode + ConnectTimeout; UNQUOTED remote source
    // (scp is SFTP-default → literal path); tmp last
    let t = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
    let tmp = URL(fileURLWithPath: "/tmp/x/spec.md.fetch")
    let fargs = SSHTransport.fetchArgs(t, tmp: tmp)
    c.expect(fargs.contains("BatchMode=yes"), "fetchArgs has BatchMode")
    c.expect(fargs.contains("ConnectTimeout=10"), "fetchArgs has ConnectTimeout")
    c.equal(fargs.last, tmp.path, "fetchArgs local tmp last")
    c.expect(fargs.contains("fabio@devbox:/a/spec.md"), "fetchArgs unquoted remote source")
    c.expect(!fargs.contains(where: { $0.contains("'") }), "fetchArgs has no shell quotes")

    // pushArgs: FLAGS first (BSD getopt stops at first non-option), then
    // local source, then UNQUOTED remote temp as the final arg
    let proxy = URL(fileURLWithPath: "/tmp/x/spec.md")
    let pargs = SSHTransport.pushArgs(proxy, to: t)
    c.equal(pargs.first, "-o", "pushArgs flags precede positionals")
    c.equal(pargs.last, "fabio@devbox:/a/spec.md.mindle-tmp", "pushArgs remote temp last")
    let pProxyIdx = pargs.firstIndex(of: proxy.path)
    let pRemoteIdx = pargs.firstIndex(of: "fabio@devbox:/a/spec.md.mindle-tmp")
    c.expect(pProxyIdx != nil && pRemoteIdx != nil && pProxyIdx! < pRemoteIdx!, "pushArgs local source before remote dest")
    c.expect(pargs.contains("BatchMode=yes"), "pushArgs has BatchMode")
    c.expect(!pargs.contains(where: { $0.contains("'") }), "pushArgs has no shell quotes")

    // remoteMvArgs: userHost present + quoted mv command + BatchMode
    let tSpace = SSHTarget(userHostPath: "fabio@devbox:/a/my notes.md")!
    let margs = SSHTransport.remoteMvArgs(tSpace)
    c.expect(margs.contains("fabio@devbox"), "remoteMvArgs has userHost")
    c.expect(margs.contains("mv '/a/my notes.md.mindle-tmp' '/a/my notes.md'"), "remoteMvArgs quoted mv")
    c.expect(margs.contains("BatchMode=yes"), "remoteMvArgs has BatchMode")

    let profile = SSHProfile(
        name: "test",
        hostname: "test",
        rootPath: "/workspace",
        favorite: true
    )!
    let listArgs = SSHTransport.listDocumentsArgs(profile)
    c.expect(listArgs.contains("test"), "listDocumentsArgs has hostname")
    c.expect(
        listArgs.last?.contains("root='/workspace'") == true,
        "listDocumentsArgs quotes configured root"
    )
    c.expect(
        listArgs.last?.contains("if [ ! -d \"$root\" ]; then root=$HOME; fi") == true,
        "listDocumentsArgs falls back to remote home"
    )
    c.expect(
        listArgs.last?.contains("find \"$root\"") == true,
        "listDocumentsArgs searches effective root"
    )
    c.expect(
        listArgs.last?.contains("-iname '*.md'") == true,
        "listDocumentsArgs includes Markdown"
    )

    let listed = """
    Welcome to Microsoft Azure Linux 3.0 (aarch64)
    \(SSHTransport.listingRootMarker)/workspace\u{0}/workspace/book/README.md\u{0}/workspace/notes.txt\u{0}
    """
    let listRunner = FakeRunner(result: ProcessResult(
        status: 0,
        stdout: listed.data(using: .utf8)!,
        stderr: Data()
    ))
    do {
        let listing = try await SSHTransport.listDocuments(in: profile, runner: listRunner)
        c.equal(listing.root.canonical, "test:/workspace", "configured root reported")
        c.equal(
            listing.files.map(\.canonical),
            ["test:/workspace/book/README.md", "test:/workspace/notes.txt"],
            "listDocuments ignores login banner and parses paths"
        )
    } catch {
        c.expect(false, "listDocuments failed: \(error)")
    }
    do {
        _ = try await SSHTransport.listDocuments(
            in: profile,
            runner: FakeRunner(result: ProcessResult(
                status: 2,
                stdout: Data(),
                stderr: Data("find failed".utf8)
            ))
        )
        c.expect(false, "listDocuments should throw on non-zero exit")
    } catch let SSHTransportError.nonZeroExit(status, stderr) {
        c.equal(status, 2, "listDocuments error status")
        c.equal(stderr, "find failed", "listDocuments error stderr")
    } catch {
        c.expect(false, "listDocuments threw wrong error: \(error)")
    }
    let fallbackOutput = """
    \(SSHTransport.listingRootMarker)/home/test\u{0}/home/test/README.md\u{0}/workspace/outside.md\u{0}
    """
    do {
        let listing = try await SSHTransport.listDocuments(
            in: profile,
            runner: FakeRunner(result: ProcessResult(
                status: 0,
                stdout: Data(fallbackOutput.utf8),
                stderr: Data()
            ))
        )
        c.equal(listing.root.canonical, "test:/home/test", "missing root falls back to remote home")
        c.equal(
            listing.files.map(\.canonical),
            ["test:/home/test/README.md"],
            "fallback listing is scoped to remote home"
        )
    } catch {
        c.expect(false, "home fallback listing failed: \(error)")
    }
    do {
        _ = try await SSHTransport.listDocuments(
            in: profile,
            runner: FakeRunner(result: ProcessResult(
                status: 0,
                stdout: Data("/workspace/README.md\u{0}".utf8),
                stderr: Data()
            ))
        )
        c.expect(false, "listing without effective root should fail")
    } catch SSHTransportError.invalidListing {
        c.expect(true, "listing without effective root rejected")
    } catch {
        c.expect(false, "malformed listing returned wrong error: \(error)")
    }

    let fallbackFixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("mindle-home-fallback-\(UUID().uuidString)", isDirectory: true)
    let existingEmptyRoot = fallbackFixture.appendingPathComponent("empty", isDirectory: true)
    do {
        try FileManager.default.createDirectory(
            at: existingEmptyRoot,
            withIntermediateDirectories: true
        )
        try "# Home".write(
            to: fallbackFixture.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let missingProfile = SSHProfile(
            name: "missing",
            hostname: "test",
            rootPath: fallbackFixture.appendingPathComponent("missing").path,
            favorite: false
        )!
        let missingResult = try await SystemProcessRunner().run(
            launchPath: "/usr/bin/env",
            arguments: [
                "HOME=\(fallbackFixture.path)",
                "/bin/sh", "-c",
                SSHTransport.listDocumentsArgs(missingProfile).last!
            ]
        )
        let missingListing = try await SSHTransport.listDocuments(
            in: missingProfile,
            runner: FakeRunner(result: missingResult)
        )
        c.equal(
            missingListing.root.remotePath,
            fallbackFixture.path,
            "generated shell command opens HOME when configured root is missing"
        )
        c.equal(
            missingListing.files.map(\.basename),
            ["README.md"],
            "generated shell command lists HOME documents"
        )

        let emptyProfile = SSHProfile(
            name: "empty",
            hostname: "test",
            rootPath: existingEmptyRoot.path,
            favorite: false
        )!
        let emptyResult = try await SystemProcessRunner().run(
            launchPath: "/usr/bin/env",
            arguments: [
                "HOME=\(fallbackFixture.path)",
                "/bin/sh", "-c",
                SSHTransport.listDocumentsArgs(emptyProfile).last!
            ]
        )
        let emptyListing = try await SSHTransport.listDocuments(
            in: emptyProfile,
            runner: FakeRunner(result: emptyResult)
        )
        c.equal(
            emptyListing.root.remotePath,
            existingEmptyRoot.path,
            "existing empty root does not fall back to HOME"
        )
        c.equal(emptyListing.files, [], "existing empty root remains empty")
    } catch {
        c.expect(false, "shell-level HOME fallback fixture failed: \(error)")
    }
    try? FileManager.default.removeItem(at: fallbackFixture)

    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("mindle-asset-fetch-\(UUID().uuidString)", isDirectory: true)
    let assetRunner = AssetRunner(failingPath: "missing.png")
    let assetFailures = await SSHTransport.fetchReferencedImages(
        in: "![ok](images/ok.png)\n![missing](images/missing.png)",
        for: SSHTarget(userHostPath: "test:/workspace/README.md")!,
        cacheDir: cache,
        runner: assetRunner
    )
    c.equal(
        assetFailures,
        [RemoteAssetFetchFailure(path: "images/missing.png", message: "missing remote asset")],
        "referenced image failures are reported"
    )
    let fetchedTargets = await assetRunner.fetchedTargets()
    c.equal(
        fetchedTargets,
        ["test:/workspace/images/ok.png", "test:/workspace/images/missing.png"],
        "referenced images fetched in document order"
    )
    c.expect(
        FileManager.default.fileExists(
            atPath: SSHTarget(userHostPath: "test:/workspace/images/ok.png")!
                .proxyURL(cacheDir: cache)
                .path
        ),
        "successful referenced image stored in cache"
    )
    try? FileManager.default.removeItem(at: cache)

    let concurrentCache = FileManager.default.temporaryDirectory
        .appendingPathComponent("mindle-concurrent-fetch-\(UUID().uuidString)", isDirectory: true)
    let concurrentTarget = SSHTarget(userHostPath: "test:/workspace/concurrent.md")!
    let concurrentProxy = concurrentTarget.proxyURL(cacheDir: concurrentCache)
    do {
        async let first: Void = SSHTransport.fetch(
            concurrentTarget,
            to: concurrentProxy,
            runner: DelayedFetchRunner(content: "first", delayNanoseconds: 30_000_000)
        )
        async let second: Void = SSHTransport.fetch(
            concurrentTarget,
            to: concurrentProxy,
            runner: DelayedFetchRunner(content: "second", delayNanoseconds: 0)
        )
        _ = try await (first, second)
        let content = try String(contentsOf: concurrentProxy, encoding: .utf8)
        c.expect(content == "first" || content == "second", "concurrent fetch leaves a complete proxy")
    } catch {
        c.expect(false, "concurrent fetch failed: \(error)")
    }
    try? FileManager.default.removeItem(at: concurrentCache)

    // shellSingleQuote
    c.equal(SSHTransport.shellSingleQuote("/a/b"), "'/a/b'", "shellSingleQuote simple")
    c.equal(SSHTransport.shellSingleQuote("it's"), "'it'\\''s'", "shellSingleQuote escapes quote")

    // fetch throws on non-zero exit (fake runner — no real ssh)
    let runner = FakeRunner(result: ProcessResult(status: 1, stdout: Data(),
                            stderr: "ssh: connect to host devbox port 22: Connection refused\n".data(using: .utf8)!))
    let proxy2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spec.md")
    do {
        try await SSHTransport.fetch(t, to: proxy2, runner: runner)
        c.expect(false, "fetch should throw on non-zero exit")
    } catch let SSHTransportError.nonZeroExit(status, stderr) {
        c.equal(status, 1, "fetch error status")
        c.expect(stderr.contains("Connection refused"), "fetch error stderr")
    } catch {
        c.expect(false, "fetch threw wrong error: \(error)")
    }

    do {
        let largeOutput = String(repeating: "x", count: 100_000)
        let result = try await SystemProcessRunner().run(
            launchPath: "/usr/bin/printf",
            arguments: ["%s", largeOutput]
        )
        c.equal(result.status, 0, "large-output process status")
        c.equal(result.stdout.count, largeOutput.utf8.count, "large process output drains without deadlock")
    } catch {
        c.expect(false, "large-output process failed: \(error)")
    }

    do {
        _ = try await SystemProcessRunner().run(
            launchPath: "/path/that/does/not/exist",
            arguments: []
        )
        c.expect(false, "missing executable should fail to launch")
    } catch SSHTransportError.launchFailed {
        c.expect(true, "missing executable reports launch failure")
    } catch {
        c.expect(false, "missing executable returned wrong error: \(error)")
    }

    if c.failures == 0 { print("✓ SSHTransport: \(c.passed) checks passed") }
    return c.failures
}

private struct FakeRunner: ProcessRunner {
    let result: ProcessResult
    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult { result }
}

private actor AssetRunner: ProcessRunner {
    let failingPath: String
    private var targets: [String] = []

    init(failingPath: String) {
        self.failingPath = failingPath
    }

    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult {
        let target = arguments[arguments.count - 2]
        targets.append(target)
        if target.hasSuffix(failingPath) {
            return ProcessResult(
                status: 1,
                stdout: Data(),
                stderr: Data("missing remote asset".utf8)
            )
        }
        try Data("image".utf8).write(to: URL(fileURLWithPath: arguments.last!))
        return ProcessResult(status: 0, stdout: Data(), stderr: Data())
    }

    func fetchedTargets() -> [String] {
        targets
    }
}

private struct DelayedFetchRunner: ProcessRunner {
    let content: String
    let delayNanoseconds: UInt64

    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult {
        try Data(content.utf8).write(to: URL(fileURLWithPath: arguments.last!))
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return ProcessResult(status: 0, stdout: Data(), stderr: Data())
    }
}
