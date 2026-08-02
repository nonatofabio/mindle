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

    /// Deterministic local proxy that mirrors the remote directory structure.
    func proxyURL(cacheDir: URL) -> URL {
        return remotePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(
                cacheDir.appendingPathComponent(Self.fnv1a(userHost), isDirectory: true)
            ) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }

    func migrateLegacyCacheIfNeeded(
        cacheDir: URL,
        fileManager: FileManager = .default
    ) throws {
        let legacyProxy = cacheDir
            .appendingPathComponent(Self.fnv1a(canonical), isDirectory: true)
            .appendingPathComponent(basename)
        let proxy = proxyURL(cacheDir: cacheDir)
        let legacySidecar = legacyProxy.deletingLastPathComponent()
            .appendingPathComponent(".\(legacyProxy.lastPathComponent).mindle.json")
        let sidecar = proxy.deletingLastPathComponent()
            .appendingPathComponent(".\(proxy.lastPathComponent).mindle.json")

        guard fileManager.fileExists(atPath: legacyProxy.path)
            || fileManager.fileExists(atPath: legacySidecar.path) else {
            return
        }
        try fileManager.createDirectory(
            at: proxy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: legacyProxy.path),
           !fileManager.fileExists(atPath: proxy.path) {
            try fileManager.moveItem(at: legacyProxy, to: proxy)
        }
        if fileManager.fileExists(atPath: legacySidecar.path),
           !fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.moveItem(at: legacySidecar, to: sidecar)
        }
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
        self.init(userHost: uh, remotePath: rp)
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
        guard rp.count > 1 else { return nil }
        self.init(userHost: uh, remotePath: rp)
    }

    init?(userHost: String, remotePath: String) {
        let normalizedHost = userHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = (remotePath as NSString).standardizingPath
        guard !normalizedHost.isEmpty,
              !normalizedHost.hasPrefix("-"),
              normalizedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !normalizedHost.contains("/"),
              normalizedPath.hasPrefix("/") else { return nil }
        self.userHost = normalizedHost
        self.remotePath = normalizedPath
    }

    /// FNV-1a 64-bit hash, hex — same family as DocumentStore's content/url
    /// hashes. Kept local so this type stays dependency-free.
    static func fnv1a(_ text: String) -> String {
        var h: UInt64 = 14695981039346656037
        for byte in text.utf8 { h ^= UInt64(byte); h = h &* 1099511628211 }
        return String(format: "%016llx", h)
    }
}
