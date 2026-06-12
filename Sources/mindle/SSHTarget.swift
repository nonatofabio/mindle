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
