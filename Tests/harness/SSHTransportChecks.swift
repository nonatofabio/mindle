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

    if c.failures == 0 { print("✓ SSHTransport: \(c.passed) checks passed") }
    return c.failures
}

private struct FakeRunner: ProcessRunner {
    let result: ProcessResult
    func run(launchPath: String, arguments: [String]) async throws -> ProcessResult { result }
}
