import Foundation

func runSSHTargetChecks() -> Int {
    let c = Checks("SSHTarget")

    // parses user@host:/path
    let t1 = SSHTarget(userHostPath: "fabio@devbox:/home/fabio/spec.md")
    c.equal(t1?.userHost, "fabio@devbox", "userHost")
    c.equal(t1?.remotePath, "/home/fabio/spec.md", "remotePath")
    c.equal(t1?.basename, "spec.md", "basename")
    c.equal(t1?.canonical, "fabio@devbox:/home/fabio/spec.md", "canonical")

    // bare alias
    let t2 = SSHTarget(userHostPath: "devbox:/srv/notes/readme.md")
    c.equal(t2?.userHost, "devbox", "alias userHost")
    c.equal(t2?.remotePath, "/srv/notes/readme.md", "alias remotePath")

    // rejects
    c.expect(SSHTarget(userHostPath: "devbox:relative/path.md") == nil, "rejects relative path")
    c.expect(SSHTarget(userHostPath: "no-colon-here") == nil, "rejects missing colon")
    c.expect(SSHTarget(userHostPath: ":/empty/host.md") == nil, "rejects empty host")
    c.expect(SSHTarget(userHostPath: "   ") == nil, "rejects blank")
    c.expect(SSHTarget(userHostPath: "-oProxyCommand=bad:/file.md") == nil, "rejects option-like host")
    c.equal(
        SSHTarget(userHostPath: "devbox:/../../etc/notes.md")?.remotePath,
        "/etc/notes.md",
        "normalizes parent components"
    )

    // sourceURL round-trips
    let t3 = SSHTarget(userHostPath: "fabio@devbox:/home/fabio/my notes.md")!
    let url = t3.sourceURL!
    c.equal(url.scheme, "mindle", "url scheme")
    c.equal(url.host, "ssh", "url host")
    c.equal(SSHTarget(sourceURL: url), t3, "sourceURL round-trip")

    // proxyURL deterministic + hash-keyed
    let dir = testFixtureURL("ssh-cache-layout")
    let a = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
    let b = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
    let other = SSHTarget(userHostPath: "fabio@other:/a/spec.md")!
    c.equal(a.proxyURL(cacheDir: dir), b.proxyURL(cacheDir: dir), "proxy deterministic")
    c.expect(a.proxyURL(cacheDir: dir) != other.proxyURL(cacheDir: dir), "proxy differs by host")
    c.equal(a.proxyURL(cacheDir: dir).lastPathComponent, "spec.md", "proxy basename")
    c.equal(
        a.proxyURL(cacheDir: dir).deletingLastPathComponent().lastPathComponent,
        "a",
        "proxy mirrors remote parent directory"
    )

    do {
        let migrationRoot = try resetTestFixture("ssh-cache-migration")
        let migrationTarget = SSHTarget(userHostPath: "devbox:/docs/guide.md")!
        let legacyProxy = migrationRoot
            .appendingPathComponent(SSHTarget.fnv1a(migrationTarget.canonical), isDirectory: true)
            .appendingPathComponent("guide.md")
        let legacySidecar = legacyProxy.deletingLastPathComponent()
            .appendingPathComponent(".guide.md.mindle.json")
        try FileManager.default.createDirectory(
            at: legacyProxy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "legacy document".write(to: legacyProxy, atomically: true, encoding: .utf8)
        try "legacy annotations".write(to: legacySidecar, atomically: true, encoding: .utf8)
        try migrationTarget.migrateLegacyCacheIfNeeded(cacheDir: migrationRoot)

        let migratedProxy = migrationTarget.proxyURL(cacheDir: migrationRoot)
        let migratedSidecar = migratedProxy.deletingLastPathComponent()
            .appendingPathComponent(".guide.md.mindle.json")
        c.equal(
            try String(contentsOf: migratedProxy, encoding: .utf8),
            "legacy document",
            "legacy proxy migrated"
        )
        c.equal(
            try String(contentsOf: migratedSidecar, encoding: .utf8),
            "legacy annotations",
            "legacy annotation sidecar migrated"
        )
        c.expect(!FileManager.default.fileExists(atPath: legacyProxy.path), "legacy proxy removed")
    } catch {
        c.expect(false, "legacy cache migration failed: \(error)")
    }

    if c.failures == 0 { print("✓ SSHTarget: \(c.passed) checks passed") }
    return c.failures
}
