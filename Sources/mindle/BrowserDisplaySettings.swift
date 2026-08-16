import Foundation

enum BrowserDisplaySettings {
    static let highlightActiveFileKey = "mindle.fileBrowser.highlightActiveFile"

    static func highlightActiveFile(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: highlightActiveFileKey) as? Bool ?? true
    }
}
