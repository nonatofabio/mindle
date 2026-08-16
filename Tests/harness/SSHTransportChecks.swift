import Foundation

func runSSHTransportChecks() async -> Int {
    let c = Checks("SSHTransport")
    let fixtureRoot: URL
    do {
        fixtureRoot = try resetTestFixture("ssh-transport")
    } catch {
        c.expect(false, "fixture setup failed: \(error)")
        return c.failures
    }

    let target = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
    let tmp = fixtureRoot.appendingPathComponent("spec.md.fetch")
    let fetchArgs = SSHTransport.fetchArgs(target, tmp: tmp)
    c.expect(fetchArgs.contains("BatchMode=yes"), "fetchArgs has BatchMode")
    c.expect(fetchArgs.contains("ConnectTimeout=10"), "fetchArgs has ConnectTimeout")
    c.equal(fetchArgs.last, tmp.path, "fetchArgs local tmp last")
    c.expect(fetchArgs.contains("fabio@devbox:/a/spec.md"), "fetchArgs unquoted remote source")
    c.expect(!fetchArgs.contains(where: { $0.contains("'") }), "fetchArgs has no shell quotes")

    let proxy = fixtureRoot.appendingPathComponent("spec.md")
    let pushArgs = SSHTransport.pushArgs(proxy, to: target)
    c.equal(pushArgs.first, "-o", "pushArgs flags precede positionals")
    c.equal(pushArgs.last, "fabio@devbox:/a/spec.md.mindle-tmp", "pushArgs remote temp last")
    c.expect(pushArgs.contains("BatchMode=yes"), "pushArgs has BatchMode")

    let spacedTarget = SSHTarget(userHostPath: "fabio@devbox:/a/my notes.md")!
    c.expect(
        SSHTransport.remoteMvArgs(spacedTarget)
            .contains("mv '/a/my notes.md.mindle-tmp' '/a/my notes.md'"),
        "remoteMvArgs quotes remote paths"
    )
    c.equal(SSHTransport.shellSingleQuote("it's"), "'it'\\''s'", "shell quote escapes apostrophe")

    let profile = SSHProfile(
        name: "test",
        hostname: "test",
        rootPath: "/workspace",
        favorite: true
    )!
    let listArgs = SSHTransport.listDocumentsArgs(profile)
    let listCommand = listArgs.last ?? ""
    c.expect(listArgs.contains("test"), "listDocumentsArgs has hostname")
    c.expect(listCommand.contains("root='/workspace'"), "listing quotes configured root")
    c.expect(
        listCommand.contains("Mindle SSH profile root does not exist"),
        "listing emits clear missing-root error"
    )
    c.expect(
        listCommand.contains("exit \(SSHTransport.missingRootExitStatus)"),
        "listing uses explicit missing-root exit status"
    )
    c.expect(!listCommand.contains("root=$HOME"), "listing never falls back to remote home")
    c.expect(listCommand.contains("find \"$root\""), "listing searches only configured root")
    c.expect(listCommand.contains("-iname '*.md'"), "listing includes Markdown")
    let resolveCommand = SSHTransport.resolveAssetArgs(
        SSHTarget(userHostPath: "test:/workspace/images/logo.png")!,
        profileRoot: profile.rootTarget
    ).last ?? ""
    c.expect(resolveCommand.contains("realpath \"$asset\""), "asset resolution follows canonical path")
    c.expect(
        resolveCommand.contains("resolves outside profile root"),
        "asset resolution rejects symlink escape"
    )

    let listed = """
    Welcome banner
    \(SSHTransport.listingRootMarker)/workspace\u{0}/workspace/book/README.md\u{0}/workspace/notes.txt\u{0}/workspace/image.png\u{0}/outside/no.md\u{0}
    """
    do {
        let listing = try await SSHTransport.listDocuments(
            in: profile,
            runner: StaticRunner(result: ProcessResult(
                status: 0,
                stdout: Data(listed.utf8),
                stderr: Data()
            ))
        )
        c.equal(listing.root.canonical, "test:/workspace", "configured root reported")
        c.equal(
            listing.files.map(\.canonical),
            ["test:/workspace/book/README.md", "test:/workspace/notes.txt"],
            "listing accepts documents only inside configured root"
        )
    } catch {
        c.expect(false, "valid listing failed: \(error)")
    }

    do {
        _ = try await SSHTransport.listDocuments(
            in: profile,
            runner: StaticRunner(result: ProcessResult(
                status: SSHTransport.missingRootExitStatus,
                stdout: Data(),
                stderr: Data("Mindle SSH profile root does not exist: /workspace\n".utf8)
            ))
        )
        c.expect(false, "missing configured root should fail")
    } catch SSHTransportError.missingRemoteRoot(let path) {
        c.equal(path, "/workspace", "missing root error names configured path")
    } catch {
        c.expect(false, "missing root returned wrong error: \(error)")
    }

    do {
        _ = try await SSHTransport.listDocuments(
            in: profile,
            runner: StaticRunner(result: ProcessResult(
                status: 0,
                stdout: Data("\(SSHTransport.listingRootMarker)/home/test\u{0}/home/test/README.md\u{0}".utf8),
                stderr: Data()
            ))
        )
        c.expect(false, "listing a substituted home root should fail")
    } catch SSHTransportError.invalidListing {
        c.expect(true, "substituted home root rejected")
    } catch {
        c.expect(false, "substituted home root returned wrong error: \(error)")
    }

    do {
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true)
        let localProfile = SSHProfile(
            name: "missing",
            hostname: "test",
            rootPath: missingRoot.path,
            favorite: false
        )!
        let homeDecoy = fixtureRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDecoy, withIntermediateDirectories: true)
        try "# Decoy".write(
            to: homeDecoy.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        let shellResult = try await SystemProcessRunner().run(
            launchPath: "/bin/sh",
            arguments: ["-c", SSHTransport.listDocumentsArgs(localProfile).last!]
        )
        c.equal(
            shellResult.status,
            SSHTransport.missingRootExitStatus,
            "generated shell command fails for missing root"
        )
        c.expect(
            String(data: shellResult.stderr, encoding: .utf8)?.contains(missingRoot.path) == true,
            "generated shell command reports exact missing root"
        )
        c.equal(shellResult.stdout, Data(), "missing root command produces no listing")
    } catch {
        c.expect(false, "shell-level missing-root fixture failed: \(error)")
    }

    do {
        let realpathFixture = fixtureRoot.appendingPathComponent("realpath", isDirectory: true)
        let confinedRoot = realpathFixture.appendingPathComponent("root", isDirectory: true)
        let outsideRoot = realpathFixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: confinedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let insideImage = confinedRoot.appendingPathComponent("inside.png")
        let outsideImage = outsideRoot.appendingPathComponent("outside.png")
        try Data("inside".utf8).write(to: insideImage)
        try Data("outside".utf8).write(to: outsideImage)
        let escapedLink = confinedRoot.appendingPathComponent("escaped.png")
        try FileManager.default.createSymbolicLink(
            at: escapedLink,
            withDestinationURL: outsideImage
        )
        let localRoot = SSHTarget(userHost: "test", remotePath: confinedRoot.path)!

        let insideResult = try await SystemProcessRunner().run(
            launchPath: "/bin/sh",
            arguments: [
                "-c",
                SSHTransport.resolveAssetArgs(
                    SSHTarget(userHost: "test", remotePath: insideImage.path)!,
                    profileRoot: localRoot
                ).last!
            ]
        )
        c.equal(insideResult.status, 0, "canonical image inside root resolves")
        c.expect(
            String(data: insideResult.stdout, encoding: .utf8)?.contains(insideImage.path) == true,
            "canonical image reports resolved path"
        )

        let escapedResult = try await SystemProcessRunner().run(
            launchPath: "/bin/sh",
            arguments: [
                "-c",
                SSHTransport.resolveAssetArgs(
                    SSHTarget(userHost: "test", remotePath: escapedLink.path)!,
                    profileRoot: localRoot
                ).last!
            ]
        )
        c.equal(
            escapedResult.status,
            SSHTransport.assetOutsideRootExitStatus,
            "symlink escape outside root is rejected"
        )
    } catch {
        c.expect(false, "shell-level canonical path fixture failed: \(error)")
    }

    let assetCache = fixtureRoot.appendingPathComponent("asset-cache", isDirectory: true)
    let linkedAsset = "/workspace/book/images/link.png"
    let assetRunner = RecordingAssetRunner(
        failingPath: "missing.png",
        resolvedPaths: [linkedAsset: "/outside/secret.png"]
    )
    let attackMarkdown = """
    ![ok](images/ok.png)
    ![missing](images/missing.png)
    ![linked escape](images/link.png)
    ![private](../../.ssh/id_rsa)
    ![script](images/payload.sh)
    ![encoded escape](%252e%252e/%252e%252e/outside.png)
    """
    let report = await SSHTransport.fetchReferencedImages(
        in: attackMarkdown,
        for: SSHTarget(userHostPath: "test:/workspace/book/README.md")!,
        profileRoot: profile.rootTarget,
        cacheDir: assetCache,
        runner: assetRunner
    )
    c.equal(report.fetchedCount, 1, "only valid successful image counted")
    c.equal(report.skippedForLimit, 0, "small document does not hit cap")
    c.equal(
        await assetRunner.fetchedTargets(),
        ["test:/workspace/book/images/ok.png", "test:/workspace/book/images/missing.png"],
        "transport never copies rejected paths"
    )
    c.expect(
        report.failures.contains(where: {
            $0.path == "images/link.png" && $0.message.contains("configured SSH root")
        }),
        "canonical symlink escape is reported"
    )
    c.expect(
        report.failures.contains(where: {
            $0.path == "../../.ssh/id_rsa" && $0.message.contains("configured SSH root")
        }),
        "root escape is reported"
    )
    c.expect(
        report.failures.contains(where: {
            $0.path == "images/payload.sh" && $0.message.contains("unsupported extension")
        }),
        "non-image extension is reported"
    )

    let cappedMarkdown = (0..<(RemoteMarkdownAssets.maxAssetsPerDocument + 5))
        .map { "![image \($0)](images/\($0).png)" }
        .joined(separator: "\n")
    let capRunner = RecordingAssetRunner()
    let capReport = await SSHTransport.fetchReferencedImages(
        in: cappedMarkdown,
        for: SSHTarget(userHostPath: "test:/workspace/book/README.md")!,
        profileRoot: profile.rootTarget,
        cacheDir: fixtureRoot.appendingPathComponent("cap-cache", isDirectory: true),
        runner: capRunner
    )
    c.equal(
        await capRunner.fetchedTargets().count,
        RemoteMarkdownAssets.maxAssetsPerDocument,
        "asset fetch count is capped"
    )
    c.equal(capReport.fetchedCount, RemoteMarkdownAssets.maxAssetsPerDocument, "cap fetch report")
    c.equal(capReport.skippedForLimit, 5, "cap reports skipped references")

    do {
        let concurrentCache = fixtureRoot.appendingPathComponent("concurrent", isDirectory: true)
        let concurrentTarget = SSHTarget(userHostPath: "test:/workspace/concurrent.md")!
        let concurrentProxy = concurrentTarget.proxyURL(cacheDir: concurrentCache)
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
        c.expect(content == "first" || content == "second", "concurrent fetch leaves complete proxy")
    } catch {
        c.expect(false, "concurrent fetch failed: \(error)")
    }

    let failedFetchRunner = StaticRunner(result: ProcessResult(
        status: 1,
        stdout: Data(),
        stderr: Data("ssh: connection refused\n".utf8)
    ))
    do {
        try await SSHTransport.fetch(
            target,
            to: fixtureRoot.appendingPathComponent("failed.md"),
            runner: failedFetchRunner
        )
        c.expect(false, "fetch should throw on non-zero exit")
    } catch let SSHTransportError.nonZeroExit(status, stderr) {
        c.equal(status, 1, "fetch error status")
        c.expect(stderr.contains("connection refused"), "fetch error stderr")
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
        c.equal(result.stdout.count, largeOutput.utf8.count, "large output drains without deadlock")
    } catch {
        c.expect(false, "large-output process failed: \(error)")
    }

    if c.failures == 0 { print("✓ SSHTransport: \(c.passed) checks passed") }
    return c.failures
}

private struct StaticRunner: ProcessRunner {
    let result: ProcessResult
    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult { result }
}

private actor RecordingAssetRunner: ProcessRunner {
    let failingPath: String?
    let resolvedPaths: [String: String]
    private var targets: [String] = []

    init(
        failingPath: String? = nil,
        resolvedPaths: [String: String] = [:]
    ) {
        self.failingPath = failingPath
        self.resolvedPaths = resolvedPaths
    }

    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult {
        if launchPath == SSHTransport.sshPath {
            let command = arguments.last ?? ""
            guard let start = command.range(of: "; asset='"),
                  let end = command[start.upperBound...].firstIndex(of: "'") else {
                return ProcessResult(
                    status: SSHTransport.assetResolutionExitStatus,
                    stdout: Data(),
                    stderr: Data("asset parse failed".utf8)
                )
            }
            let path = String(command[start.upperBound..<end])
            let resolved = resolvedPaths[path] ?? path
            return ProcessResult(
                status: 0,
                stdout: Data((
                    "\(SSHTransport.listingRootMarker)/workspace\u{0}"
                        + "\(SSHTransport.resolvedAssetMarker)\(resolved)\u{0}"
                ).utf8),
                stderr: Data()
            )
        }
        let target = arguments[arguments.count - 2]
        targets.append(target)
        if let failingPath, target.hasSuffix(failingPath) {
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
