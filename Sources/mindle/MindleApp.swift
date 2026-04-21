import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    var store: DocumentStore?
    private var pendingURLs: [URL] = []

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let store = store {
            if let first = urls.first {
                store.open(url: first)
            }
        } else {
            // Called before the SwiftUI scene attaches; buffer and replay.
            pendingURLs.append(contentsOf: urls)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func attach(store: DocumentStore) {
        self.store = store
        if let first = pendingURLs.first {
            store.open(url: first)
            pendingURLs.removeAll()
        }
    }
}

@main
struct MindleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 560)
                .onAppear {
                    appDelegate.attach(store: store)
                    let args = CommandLine.arguments.dropFirst()
                    if let path = args.first(where: { !$0.hasPrefix("-") }) {
                        store.open(url: URL(fileURLWithPath: path))
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { store.openWithPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Export Annotations…") { store.exportAnnotationsWithPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!store.canExportAnnotations)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Highlight Selection") {
                    store.showAnnotations = true
                    store.highlightSelection()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Add Note to Selection…") {
                    store.showAnnotations = true
                    store.addNoteToSelection()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { store.toggleSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(store.fileURL == nil)
                Button("Find Next") { store.nextMatch() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!store.showSearch || store.searchTotal == 0)
                Button("Find Previous") { store.previousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!store.showSearch || store.searchTotal == 0)
            }
            CommandGroup(after: .sidebar) {
                Button(store.showFileBrowser ? "Hide Files" : "Show Files") {
                    store.showFileBrowser.toggle()
                    if store.showFileBrowser && store.fileTree == nil {
                        store.refreshFileTree()
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.fileURL == nil)

                Button(store.showAnnotations ? "Hide Annotations" : "Show Annotations") {
                    store.showAnnotations.toggle()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Increase Font Size") { store.fontScale = min(1.6, store.fontScale + 0.05) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") { store.fontScale = max(0.75, store.fontScale - 0.05) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Toggle Theme") { store.toggleTheme() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}
