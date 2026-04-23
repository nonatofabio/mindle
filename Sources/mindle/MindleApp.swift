import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private var pendingURLs: [URL] = []
    private weak var activeStore: DocumentStore?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let store = activeStore {
            for url in urls {
                store.open(url: url)
            }
        } else {
            // Called before any RootView has registered its store; buffer
            // and replay into the first window that appears.
            pendingURLs.append(contentsOf: urls)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Each window's RootView calls this on appear, so the most recently
    /// active window becomes the target for externally opened URLs.
    func register(store: DocumentStore) {
        activeStore = store
        if !pendingURLs.isEmpty {
            let queued = pendingURLs
            pendingURLs.removeAll()
            // Open the first queued URL (the buffered one from cold launch).
            if let first = queued.first {
                store.open(url: first)
            }
        }
    }
}

@main
struct MindleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "mindle-window") {
            RootView()
                .frame(minWidth: 780, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            MindleCommands()
        }
    }
}

/// Owns a per-window `DocumentStore`. Because `@StateObject` lives on the
/// view instance and a new `RootView` is built for every `WindowGroup`
/// window, each window gets its own independent store — fileURL,
/// annotations, theme, search state, the lot.
struct RootView: View {
    @StateObject private var store = DocumentStore()

    var body: some View {
        ContentView()
            .environmentObject(store)
            .focusedSceneObject(store)
            .onAppear {
                AppDelegate.shared?.register(store: store)
                // Command-line path argument only meaningful for the first
                // window at launch; subsequent windows open empty.
                let args = CommandLine.arguments.dropFirst()
                if store.fileURL == nil,
                   let path = args.first(where: { !$0.hasPrefix("-") }) {
                    store.open(url: URL(fileURLWithPath: path))
                }
            }
    }
}

struct MindleCommands: Commands {
    @FocusedObject private var store: DocumentStore?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Mindle") { showAboutPanel() }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "mindle-window") }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Open…") { store?.openWithPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store == nil)
            Divider()
            Button("Export Annotations…") { store?.exportAnnotationsWithPanel() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(store?.canExportAnnotations ?? false))
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Highlight Selection") {
                store?.showAnnotations = true
                store?.highlightSelection()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(store == nil)

            Button("Add Note to Selection…") {
                store?.showAnnotations = true
                store?.addNoteToSelection()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { store?.toggleSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(store?.fileURL == nil)

            Button("Find Next") { store?.nextMatch() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!(store?.showSearch ?? false) || (store?.searchTotal ?? 0) == 0)

            Button("Find Previous") { store?.previousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!(store?.showSearch ?? false) || (store?.searchTotal ?? 0) == 0)
        }

        CommandGroup(after: .sidebar) {
            Button((store?.showFileBrowser ?? false) ? "Hide Files" : "Show Files") {
                guard let store else { return }
                store.showFileBrowser.toggle()
                if store.showFileBrowser && store.fileTree == nil {
                    store.refreshFileTree()
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(store?.fileURL == nil)

            Button((store?.showAnnotations ?? false) ? "Hide Annotations" : "Show Annotations") {
                store?.showAnnotations.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(store == nil)

            Button("Increase Font Size") {
                guard let store else { return }
                store.fontScale = min(1.6, store.fontScale + 0.05)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(store == nil)

            Button("Decrease Font Size") {
                guard let store else { return }
                store.fontScale = max(0.75, store.fontScale - 0.05)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(store == nil)

            Button("Toggle Theme") { store?.toggleTheme() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(store == nil)
        }
    }
}

@MainActor
private func showAboutPanel() {
    let body = NSMutableAttributedString(
        string: "A quiet place to read Markdown.\n\n",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
    )
    let coffee = NSMutableAttributedString(
        string: "☕ Buy me a coffee",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.linkColor,
            .link: URL(string: "https://buymeacoffee.com/nonatofabio")!,
            .cursor: NSCursor.pointingHand
        ]
    )
    body.append(coffee)

    NSApp.orderFrontStandardAboutPanel(options: [
        .credits: body
    ])
    NSApp.activate(ignoringOtherApps: true)
}
