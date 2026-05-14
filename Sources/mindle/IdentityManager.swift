// IdentityManager.swift — Local user identity for team collaboration.
// ObservableObject so SwiftUI views refresh when identity changes.

import Foundation
import SwiftUI

final class IdentityManager: ObservableObject {
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

    @Published var alias: String
    @Published var displayName: String
    @Published var color: String

    var isConfigured: Bool { !alias.isEmpty && alias != "user" }

    private init() {
        alias = UserDefaults.standard.string(forKey: Keys.alias) ?? "user"
        displayName = UserDefaults.standard.string(forKey: Keys.displayName) ?? "user"
        color = UserDefaults.standard.string(forKey: Keys.color) ?? Self.defaultColors[0]
    }

    func save(alias: String, displayName: String, color: String) {
        self.alias = alias
        self.displayName = displayName
        self.color = color
        defaults.set(alias, forKey: Keys.alias)
        defaults.set(displayName, forKey: Keys.displayName)
        defaults.set(color, forKey: Keys.color)
    }

    /// Returns a SidecarCollaborator for the current user.
    func asSidecarCollaborator() -> DocumentStore.SidecarCollaborator {
        DocumentStore.SidecarCollaborator(displayName: displayName, color: color, type: "human")
    }
}
