// IdentityManager.swift — Local user identity for team collaboration.
// Stores alias, display name, and color in UserDefaults.

import Foundation

final class IdentityManager {
    static let shared = IdentityManager()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let alias = "collab.alias"
        static let displayName = "collab.displayName"
        static let color = "collab.color"
    }

    static let defaultColors: [String] = [
        "#4A90D9", "#E57373", "#81C784", "#FFB74D",
        "#BA68C8", "#4DD0E1", "#F06292", "#AED581"
    ]

    var isConfigured: Bool { defaults.string(forKey: Keys.alias) != nil }

    var alias: String {
        defaults.string(forKey: Keys.alias) ?? "user"
    }

    var displayName: String {
        defaults.string(forKey: Keys.displayName) ?? alias
    }

    var color: String {
        defaults.string(forKey: Keys.color) ?? Self.defaultColors[0]
    }

    func save(alias: String, displayName: String, color: String) {
        defaults.set(alias, forKey: Keys.alias)
        defaults.set(displayName, forKey: Keys.displayName)
        defaults.set(color, forKey: Keys.color)
    }

    /// Returns a SidecarCollaborator for the current user.
    func asSidecarCollaborator() -> DocumentStore.SidecarCollaborator {
        DocumentStore.SidecarCollaborator(displayName: displayName, color: color, type: "human")
    }
}
