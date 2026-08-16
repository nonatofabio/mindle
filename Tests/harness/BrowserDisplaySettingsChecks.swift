import Foundation

func runBrowserDisplaySettingsChecks() -> Int {
    let checks = Checks("BrowserDisplaySettings")
    let suiteName = "BrowserDisplaySettingsChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    checks.expect(
        BrowserDisplaySettings.highlightActiveFile(defaults: defaults),
        "active-file highlighting defaults on"
    )

    defaults.set(false, forKey: BrowserDisplaySettings.highlightActiveFileKey)
    checks.expect(
        !BrowserDisplaySettings.highlightActiveFile(defaults: defaults),
        "stored active-file preference is respected"
    )

    print("BrowserDisplaySettings: \(checks.passed) passed, \(checks.failures) failed")
    return checks.failures
}
