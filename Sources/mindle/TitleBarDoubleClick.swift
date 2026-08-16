import AppKit

enum TitleBarDoubleClick {
    static func perform(
        on window: NSWindow,
        preference: String? = UserDefaults.standard.string(
            forKey: "AppleActionOnDoubleClick"
        )
    ) {
        switch preference?.lowercased() {
        case "minimize":
            window.miniaturize(nil)
        case "none":
            break
        default:
            window.performZoom(nil)
        }
    }
}
