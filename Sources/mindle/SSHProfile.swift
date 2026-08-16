import Foundation

struct SSHProfile: Identifiable, Equatable, Sendable {
    let name: String
    let rootTarget: SSHTarget
    let favorite: Bool

    var id: String { name }
    var hostname: String { rootTarget.userHost }
    var rootPath: String { rootTarget.remotePath }

    init?(name: String, hostname: String, rootPath: String, favorite: Bool) {
        guard let rootTarget = SSHTarget(userHost: hostname, remotePath: rootPath) else {
            return nil
        }
        self.name = name
        self.rootTarget = rootTarget
        self.favorite = favorite
    }

    func contains(_ target: SSHTarget) -> Bool {
        guard target.userHost == hostname else { return false }
        if target.remotePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return target.remotePath.hasPrefix(prefix)
    }
}

enum SSHProfileConfigurationError: Error, LocalizedError {
    case unavailable
    case invalidLine(Int, String)
    case missingField(Int, String)
    case invalidPath(Int, String)
    case invalidHostname(Int, String)
    case invalidFavorite(Int, String)
    case duplicateFavorite
    case noProfiles

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Mindle couldn't locate its Application Support directory."
        case .invalidLine(let line, let text):
            return "SSH profiles YAML line \(line) isn't valid: \(text)"
        case .missingField(let line, let field):
            return "SSH profile near line \(line) is missing '\(field)'."
        case .invalidPath(let line, let path):
            return "SSH profile near line \(line) needs an absolute path, not '\(path)'."
        case .invalidHostname(let line, let hostname):
            return "SSH profile near line \(line) has invalid hostname '\(hostname)'."
        case .invalidFavorite(let line, let value):
            return "SSH profile near line \(line) has invalid favorite value '\(value)'. Use true or false."
        case .duplicateFavorite:
            return "Only one SSH profile can be marked favorite."
        case .noProfiles:
            return "No SSH profiles are configured. Edit ssh-profiles.yaml to enable one."
        }
    }
}

enum SSHProfileConfiguration {
    static let defaultYAML = """
    # Configure one or more SSH roots, then remove the leading "# " markers.
    # profiles:
    #   - name: docs
    #     hostname: docs.example
    #     path: /srv/docs
    #     favorite: true
    """

    static func configURL(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SSHProfileConfigurationError.unavailable
        }
        return support
            .appendingPathComponent("Mindle", isDirectory: true)
            .appendingPathComponent("ssh-profiles.yaml")
    }

    @discardableResult
    static func ensureConfigExists(fileManager: FileManager = .default) throws -> URL {
        let url = try configURL(fileManager: fileManager)
        guard !fileManager.fileExists(atPath: url.path) else { return url }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try defaultYAML.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func load(fileManager: FileManager = .default) throws -> [SSHProfile] {
        let url = try ensureConfigExists(fileManager: fileManager)
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    static func favoriteProfile(in profiles: [SSHProfile]) -> SSHProfile? {
        profiles.first(where: \.favorite) ?? profiles.first
    }

    static func profile(containing target: SSHTarget, in profiles: [SSHProfile]) -> SSHProfile? {
        profiles
            .filter { $0.contains(target) }
            .max { $0.rootPath.count < $1.rootPath.count }
    }

    static func parse(_ yaml: String) throws -> [SSHProfile] {
        struct Draft {
            let line: Int
            var fields: [String: String]
        }

        var drafts: [Draft] = []
        var current: Draft?
        var sawProfiles = false

        func finishCurrent() {
            if let current {
                drafts.append(current)
            }
            current = nil
        }

        for (index, rawLine) in yaml.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "profiles:" {
                finishCurrent()
                sawProfiles = true
                continue
            }
            guard sawProfiles else {
                throw SSHProfileConfigurationError.invalidLine(lineNumber, line)
            }

            if line.hasPrefix("-") {
                finishCurrent()
                current = Draft(line: lineNumber, fields: [:])
                let remainder = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty {
                    let (key, value) = try field(in: String(remainder), line: lineNumber)
                    current!.fields[key] = value
                }
            } else {
                guard current != nil else {
                    throw SSHProfileConfigurationError.invalidLine(lineNumber, line)
                }
                let (key, value) = try field(in: line, line: lineNumber)
                current!.fields[key] = value
            }
        }
        finishCurrent()

        guard !drafts.isEmpty else {
            throw SSHProfileConfigurationError.noProfiles
        }

        var favoriteCount = 0
        let profiles = try drafts.map { draft -> SSHProfile in
            guard let name = nonEmpty(draft.fields["name"]) else {
                throw SSHProfileConfigurationError.missingField(draft.line, "name")
            }
            guard let hostname = nonEmpty(draft.fields["hostname"]) else {
                throw SSHProfileConfigurationError.missingField(draft.line, "hostname")
            }
            guard let rootPath = nonEmpty(draft.fields["path"]) else {
                throw SSHProfileConfigurationError.missingField(draft.line, "path")
            }
            guard rootPath.hasPrefix("/") else {
                throw SSHProfileConfigurationError.invalidPath(draft.line, rootPath)
            }

            let favorite: Bool
            switch draft.fields["favorite"]?.lowercased() {
            case nil, "false":
                favorite = false
            case "true":
                favorite = true
                favoriteCount += 1
            case let value?:
                throw SSHProfileConfigurationError.invalidFavorite(draft.line, value)
            }

            guard let profile = SSHProfile(
                name: name,
                hostname: hostname,
                rootPath: rootPath,
                favorite: favorite
            ) else {
                throw SSHProfileConfigurationError.invalidHostname(draft.line, hostname)
            }
            return profile
        }

        guard favoriteCount <= 1 else {
            throw SSHProfileConfigurationError.duplicateFavorite
        }
        return profiles
    }

    private static func field(in text: String, line: Int) throws -> (String, String) {
        guard let colon = text.firstIndex(of: ":") else {
            throw SSHProfileConfigurationError.invalidLine(line, text)
        }
        let key = text[..<colon].trimmingCharacters(in: .whitespaces)
        let rawValue = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !rawValue.isEmpty else {
            throw SSHProfileConfigurationError.invalidLine(line, text)
        }
        return (key, unquote(rawValue))
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
                continue
            }
            if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        if first == "\"" {
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return inner.replacingOccurrences(of: "''", with: "'")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
