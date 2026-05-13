// DebugConsoleWindow.swift — Floating debug console for annotation/collab events.
// Toggle with ⌘⇧D. Hidden from menus — developer use only.

import SwiftUI
import AppKit

final class DebugConsole {
    static let shared = DebugConsole()

    private var window: NSWindow?
    private(set) var messages: [String] = []
    private let maxMessages = 500

    func toggle() {
        if let w = window, w.isVisible {
            w.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 520, height: 300),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Mindle Debug Console"
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DebugConsoleView())
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        messages.append(entry)
        if messages.count > maxMessages { messages.removeFirst() }
        NotificationCenter.default.post(name: .debugConsoleDidLog, object: entry)
    }
}

extension Notification.Name {
    static let debugConsoleDidLog = Notification.Name("debugConsoleDidLog")
}

struct DebugConsoleView: View {
    @State private var lines: [String] = DebugConsole.shared.messages

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding(8)
            }
            .background(Color.black)
            .onChange(of: lines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .frame(minWidth: 300, minHeight: 150)
        .onReceive(NotificationCenter.default.publisher(for: .debugConsoleDidLog)) { notif in
            if let entry = notif.object as? String {
                lines.append(entry)
                if lines.count > 500 { lines.removeFirst() }
            }
        }
    }
}
