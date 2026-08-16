import AppKit
import SwiftUI

enum ReaderTheme: String, CaseIterable, Codable {
    case light
    case sepia
    case dark
}

@MainActor
private final class Issue36HarnessState: ObservableObject {
    @Published var tabCount = 5
}

private struct Issue36HarnessView: View {
    @ObservedObject var state: Issue36HarnessState
    let browser: FileBrowserState

    var body: some View {
        VStack(spacing: 0) {
            if state.tabCount >= 2 {
                HStack {
                    Text("Tabs")
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 31)
            }

            FileBrowserSidebar(
                browser: browser,
                theme: .light,
                onRefresh: {},
                onOpen: { _ in }
            )
        }
        .frame(width: 320, height: 600)
    }
}

@main
@MainActor
struct FileBrowserScrollStabilityTests {
    private static let tolerance: CGFloat = 0.5

    static func main() async {
        _ = NSApplication.shared
        let fixture = makeFixture()

        do {
            let result = try await measure(fixture: fixture)
            guard result.maxDelta <= tolerance else {
                fail(
                    "Flattened sidebar moved by \(format(result.maxDelta)) pt "
                        + "(tolerance \(format(tolerance)) pt)."
                )
            }

            print(
                "✓ Issue #36: \(result.measurementCount) tab/selection transitions "
                    + "held within \(format(result.maxDelta)) pt"
            )
        } catch {
            fail("Issue #36 harness failed: \(error)")
        }
    }

    private static func measure(
        fixture: (root: URL, tree: FileNode, files: [URL])
    ) async throws -> (measurementCount: Int, maxDelta: CGFloat) {
        let browser = FileBrowserState(
            treeBuilder: { _ in fixture.tree },
            metadataBuilder: { _ in .empty }
        )
        browser.setRoot(fixture.root)
        while browser.isLoading {
            try await Task.sleep(for: .milliseconds(1))
        }

        let state = Issue36HarnessState()
        let activeURL = fixture.files[fixture.files.count * 3 / 4]
        browser.setSelectedURL(activeURL)

        let hostingView = NSHostingView(
            rootView: Issue36HarnessView(
                state: state,
                browser: browser
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        settle(hostingView, window: window)

        guard let initialScrollView = firstScrollView(in: hostingView),
              let documentView = initialScrollView.documentView else {
            throw HarnessError.scrollViewMissing
        }
        let maximumOffset = max(
            0,
            documentView.bounds.height - initialScrollView.contentView.bounds.height
        )
        guard maximumOffset > 1_000 else {
            throw HarnessError.contentTooShort(maximumOffset)
        }
        var measurementCount = 0
        var maxDelta: CGFloat = 0
        for fraction in stride(from: 0.05, through: 0.90, by: 0.05) {
            state.tabCount = 5
            browser.setSelectedURL(activeURL)
            settle(hostingView, window: window)

            guard let scrollView = firstScrollView(in: hostingView) else {
                throw HarnessError.scrollViewMissing
            }
            let targetOffset = maximumOffset * fraction
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            settle(hostingView, window: window)
            let baseline = scrollView.contentView.bounds.origin.y
            for tabCount in [4, 3, 2, 1, 2, 5] {
                state.tabCount = tabCount
                settle(hostingView, window: window)
                guard let scrollView = firstScrollView(in: hostingView) else {
                    throw HarnessError.scrollViewMissing
                }
                let offset = scrollView.contentView.bounds.origin.y
                maxDelta = max(maxDelta, abs(offset - baseline))
                measurementCount += 1
            }

            for selectedURL in [
                fixture.files[fixture.files.count / 4],
                activeURL,
                fixture.files[fixture.files.count / 2],
                activeURL
            ] {
                browser.setSelectedURL(selectedURL)
                settle(hostingView, window: window)
                guard let scrollView = firstScrollView(in: hostingView) else {
                    throw HarnessError.scrollViewMissing
                }
                let offset = scrollView.contentView.bounds.origin.y
                maxDelta = max(maxDelta, abs(offset - baseline))
                measurementCount += 1
            }

            if let directoryURL = fixture.tree.children?.first?.url {
                browser.toggleDirectory(directoryURL)
                settle(hostingView, window: window)
                browser.toggleDirectory(directoryURL)
                settle(hostingView, window: window)
                guard let scrollView = firstScrollView(in: hostingView) else {
                    throw HarnessError.scrollViewMissing
                }
                let offset = scrollView.contentView.bounds.origin.y
                maxDelta = max(maxDelta, abs(offset - baseline))
                measurementCount += 1
            }
        }

        window.orderOut(nil)
        window.contentView = nil
        return (measurementCount, maxDelta)
    }

    private static func makeFixture() -> (root: URL, tree: FileNode, files: [URL]) {
        let root = URL(fileURLWithPath: "/issue-36-fixture", isDirectory: true)
        var files: [URL] = []
        let directories = (0..<48).map { directoryIndex -> FileNode in
            let directory = root.appendingPathComponent(
                String(format: "section-%02d", directoryIndex),
                isDirectory: true
            )
            let children = (0..<24).map { fileIndex -> FileNode in
                let file = directory.appendingPathComponent(
                    String(format: "document-%02d-%02d.md", directoryIndex, fileIndex)
                )
                files.append(file)
                return FileNode(
                    url: file,
                    name: file.lastPathComponent,
                    isDirectory: false,
                    children: nil
                )
            }
            return FileNode(
                url: directory,
                name: directory.lastPathComponent,
                isDirectory: true,
                children: children
            )
        }
        return (
            root,
            FileNode(
                url: root,
                name: root.lastPathComponent,
                isDirectory: true,
                children: directories
            ),
            files
        )
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private static func settle(_ hostingView: NSView, window: NSWindow) {
        for _ in 0..<5 {
            hostingView.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private static func fail(_ message: String) -> Never {
        fputs("✗ \(message)\n", stderr)
        exit(1)
    }

    private enum HarnessError: Error {
        case scrollViewMissing
        case contentTooShort(CGFloat)
    }
}
