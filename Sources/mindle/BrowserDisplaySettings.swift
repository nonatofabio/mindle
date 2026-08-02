import Foundation

enum BrowserDisplaySettings {
    static let showGitChangesKey = "mindle.fileBrowser.showGitChanges"
    static let showLastEditedKey = "mindle.fileBrowser.showLastEdited"
    static let highlightActiveFileKey = "mindle.fileBrowser.highlightActiveFile"

    static func showGitChanges(defaults: UserDefaults = .standard) -> Bool {
        enabledByDefault(showGitChangesKey, defaults: defaults)
    }

    static func showLastEdited(defaults: UserDefaults = .standard) -> Bool {
        enabledByDefault(showLastEditedKey, defaults: defaults)
    }

    static func highlightActiveFile(defaults: UserDefaults = .standard) -> Bool {
        enabledByDefault(highlightActiveFileKey, defaults: defaults)
    }

    private static func enabledByDefault(_ key: String, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
