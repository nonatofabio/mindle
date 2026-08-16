import Foundation

enum RemoteAssetPathError: Error, Equatable, LocalizedError {
    case invalidPath(String)
    case outsideProfileRoot(String)
    case unsupportedExtension(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "Rejected invalid remote image path '\(path)'."
        case .outsideProfileRoot(let path):
            return "Rejected remote image outside the configured SSH root: '\(path)'."
        case .unsupportedExtension(let path):
            return "Rejected remote image with an unsupported extension: '\(path)'."
        }
    }
}

enum RemoteMarkdownAssets {
    static let allowedExtensions: Set<String> = [
        "avif", "gif", "jpeg", "jpg", "png", "svg", "webp"
    ]
    static let maxAssetsPerDocument = 32

    static func relativePaths(in markdown: String) -> [String] {
        var paths: [String] = []
        var seen: Set<String> = []

        func appendMatches(pattern: String, allowedLabels: Set<String>? = nil) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(markdown.startIndex..., in: markdown)
            for match in regex.matches(in: markdown, range: range) {
                if let allowedLabels,
                   let labelRange = Range(match.range(at: 1), in: markdown) {
                    let label = String(markdown[labelRange]).lowercased()
                    guard allowedLabels.contains(label) else { continue }
                }
                let firstPathCapture = allowedLabels == nil ? 1 : 2
                let candidate = [firstPathCapture, firstPathCapture + 1].compactMap { capture in
                    Range(match.range(at: capture), in: markdown).map { String(markdown[$0]) }
                }.first
                guard let path = normalizedCandidate(candidate),
                      seen.insert(path).inserted else {
                    continue
                }
                paths.append(path)
            }
        }

        appendMatches(pattern: #"!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s\)]+))"#)

        let referenceRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\[([^\]]*)\]"#)
        let fullRange = NSRange(markdown.startIndex..., in: markdown)
        let labels: [String] = referenceRegex?.matches(in: markdown, range: fullRange).compactMap {
            let explicit = Range($0.range(at: 2), in: markdown).map { String(markdown[$0]) } ?? ""
            let fallback = Range($0.range(at: 1), in: markdown).map { String(markdown[$0]) } ?? ""
            let label = explicit.isEmpty ? fallback : explicit
            return label.isEmpty ? nil : label.lowercased()
        } ?? []
        let referencedLabels = Set(labels)
        if !referencedLabels.isEmpty {
            appendMatches(
                pattern: #"(?m)^\s*\[([^\]]+)\]:\s*(?:<([^>]+)>|(\S+))"#,
                allowedLabels: referencedLabels
            )
        }
        return paths
    }

    static func target(
        for relativePath: String,
        from document: SSHTarget,
        confinedTo profileRoot: SSHTarget
    ) throws -> SSHTarget {
        guard document.userHost == profileRoot.userHost,
              contains(document.remotePath, in: profileRoot.remotePath) else {
            throw RemoteAssetPathError.outsideProfileRoot(document.remotePath)
        }
        guard let relative = normalizedCandidate(relativePath),
              !relative.hasPrefix("/"),
              !relative.hasPrefix("~"),
              !relative.contains("\\"),
              relative.rangeOfCharacter(from: .controlCharacters) == nil,
              relative.range(
                of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                options: .regularExpression
              ) == nil else {
            throw RemoteAssetPathError.invalidPath(relativePath)
        }

        let parent = (document.remotePath as NSString).deletingLastPathComponent
        let normalized = ((parent as NSString).appendingPathComponent(relative) as NSString)
            .standardizingPath
        guard contains(normalized, in: profileRoot.remotePath) else {
            throw RemoteAssetPathError.outsideProfileRoot(relativePath)
        }
        guard let target = SSHTarget(userHost: document.userHost, remotePath: normalized) else {
            throw RemoteAssetPathError.invalidPath(relativePath)
        }
        try validate(target, confinedTo: profileRoot, originalPath: relativePath)
        return target
    }

    static func validate(
        _ target: SSHTarget,
        confinedTo profileRoot: SSHTarget,
        originalPath: String
    ) throws {
        guard target.userHost == profileRoot.userHost,
              contains(target.remotePath, in: profileRoot.remotePath) else {
            throw RemoteAssetPathError.outsideProfileRoot(originalPath)
        }
        let ext = (target.remotePath as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw RemoteAssetPathError.unsupportedExtension(originalPath)
        }
    }

    private static func normalizedCandidate(_ candidate: String?) -> String? {
        guard var path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        for _ in 0..<4 {
            guard let decoded = path.removingPercentEncoding else { break }
            if decoded == path { break }
            path = decoded
        }
        return path.isEmpty ? nil : path
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        let normalizedPath = (path as NSString).standardizingPath
        let normalizedRoot = (root as NSString).standardizingPath
        if normalizedPath == normalizedRoot { return true }
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return normalizedPath.hasPrefix(prefix)
    }
}
