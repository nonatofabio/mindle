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

    // sourceURL round-trips
    let t3 = SSHTarget(userHostPath: "fabio@devbox:/home/fabio/my notes.md")!
    let url = t3.sourceURL!
    c.equal(url.scheme, "mindle", "url scheme")
    c.equal(url.host, "ssh", "url host")
    c.equal(SSHTarget(sourceURL: url), t3, "sourceURL round-trip")

    // proxyURL deterministic + hash-keyed
    let dir = URL(fileURLWithPath: "/tmp/ssh-cache", isDirectory: true)
    let a = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
    let b = SSHTarget(userHostPath: "fabio@devbox:/a/spec.md")!
    let other = SSHTarget(userHostPath: "fabio@other:/a/spec.md")!
    c.equal(a.proxyURL(cacheDir: dir), b.proxyURL(cacheDir: dir), "proxy deterministic")
    c.expect(a.proxyURL(cacheDir: dir) != other.proxyURL(cacheDir: dir), "proxy differs by host")
    c.equal(a.proxyURL(cacheDir: dir).lastPathComponent, "spec.md", "proxy basename")

    if c.failures == 0 { print("✓ SSHTarget: \(c.passed) checks passed") }
    return c.failures
}
