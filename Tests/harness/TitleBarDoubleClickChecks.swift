import AppKit

func runTitleBarDoubleClickChecks() -> Int {
    let checks = Checks("TitleBarDoubleClick")
    let window = RecordingWindow()

    TitleBarDoubleClick.perform(on: window, preference: "Maximize")
    checks.equal(window.zoomCount, 1, "Maximize preference zooms")
    checks.equal(window.miniaturizeCount, 0, "Maximize does not minimize")

    TitleBarDoubleClick.perform(on: window, preference: "Minimize")
    checks.equal(window.miniaturizeCount, 1, "Minimize preference minimizes")

    TitleBarDoubleClick.perform(on: window, preference: "None")
    checks.equal(window.zoomCount, 1, "None leaves zoom unchanged")
    checks.equal(window.miniaturizeCount, 1, "None leaves minimize unchanged")

    TitleBarDoubleClick.perform(on: window, preference: nil)
    checks.equal(window.zoomCount, 2, "missing preference defaults to zoom")

    print("TitleBarDoubleClick: \(checks.passed) passed, \(checks.failures) failed")
    return checks.failures
}

private final class RecordingWindow: NSWindow {
    var zoomCount = 0
    var miniaturizeCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
    }

    override func performZoom(_ sender: Any?) {
        zoomCount += 1
    }

    override func miniaturize(_ sender: Any?) {
        miniaturizeCount += 1
    }
}
