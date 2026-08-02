import Foundation

enum RemoteMarkdownAssets {
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
                guard let path = normalizedRelativePath(candidate), seen.insert(path).inserted else {
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

    static func target(for relativePath: String, from document: SSHTarget) -> SSHTarget? {
        guard let relative = normalizedRelativePath(relativePath) else { return nil }
        let parent = (document.remotePath as NSString).deletingLastPathComponent
        let joined = (parent as NSString).appendingPathComponent(relative)
        let normalized = (joined as NSString).standardizingPath
        return SSHTarget(userHost: document.userHost, remotePath: normalized)
    }

    private static func normalizedRelativePath(_ candidate: String?) -> String? {
        guard var path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        if let marker = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<marker])
        }
        if let decoded = path.removingPercentEncoding {
            path = decoded
        }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              URL(string: path)?.scheme == nil else {
            return nil
        }
        return path
    }
}
