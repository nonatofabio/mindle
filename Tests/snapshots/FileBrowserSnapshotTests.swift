import AppKit
import SwiftUI

@main
@MainActor
struct FileBrowserSnapshotTests {
    private static let size = NSSize(width: 320, height: 360)

    static func main() throws {
        _ = NSApplication.shared
        let record = CommandLine.arguments.contains("--record")
        let fixtures: [(String, ReaderTheme, SnapshotState)] = [
            ("file-browser-light", .light, .populated),
            ("file-browser-dark", .dark, .populated),
            ("file-browser-empty", .light, .empty),
            ("file-browser-error", .dark, .error)
        ]

        var failures = 0
        for (name, theme, state) in fixtures {
            let actual = try render(theme: theme, state: state)
            let baselineURL = URL(fileURLWithPath: "Tests/snapshots/\(name).png")
            if record {
                try actual.write(to: baselineURL, options: .atomic)
                print("Recorded \(baselineURL.path)")
                continue
            }

            guard let expected = try? Data(contentsOf: baselineURL) else {
                print("✗ Missing snapshot: \(baselineURL.path)")
                failures += 1
                continue
            }
            if actual == expected {
                print("✓ \(name)")
                continue
            }

            let difference = try imageDifference(expected: expected, actual: actual)
            if difference.meanChannelDelta <= 0.015
                && difference.changedPixelFraction <= 0.025 {
                print("✓ \(name) (within rendering tolerance)")
            } else {
                let outputURL = URL(fileURLWithPath: ".build/\(name)-actual.png")
                try actual.write(to: outputURL, options: .atomic)
                print(
                    "✗ \(name): mean delta \(formatted(difference.meanChannelDelta)), "
                    + "changed pixels \(formatted(difference.changedPixelFraction)); "
                    + "actual written to \(outputURL.path)"
                )
                failures += 1
            }
        }

        if failures > 0 {
            exit(1)
        }
        print("ALL SCREENSHOT TESTS PASSED")
    }

    private static func render(theme: ReaderTheme, state: SnapshotState) throws -> Data {
        let root = URL(fileURLWithPath: "/fixture/Field Notes", isDirectory: true)
        let chapters = root.appendingPathComponent("Chapters", isDirectory: true)
        let active = chapters.appendingPathComponent("01-introduction.md")
        let draft = chapters.appendingPathComponent("02-open-questions.md")
        let notes = root.appendingPathComponent("meeting-notes.txt")
        let populatedTree = FileNode(
            url: root,
            name: root.lastPathComponent,
            isDirectory: true,
            children: [
                FileNode(
                    url: chapters,
                    name: "Chapters",
                    isDirectory: true,
                    children: [
                        FileNode(
                            url: active,
                            name: "01-introduction.md",
                            isDirectory: false,
                            children: nil
                        ),
                        FileNode(
                            url: draft,
                            name: "02-open-questions.md",
                            isDirectory: false,
                            children: nil
                        )
                    ]
                ),
                FileNode(
                    url: notes,
                    name: "meeting-notes.txt",
                    isDirectory: false,
                    children: nil
                )
            ]
        )
        let emptyTree = FileNode(
            url: root,
            name: root.lastPathComponent,
            isDirectory: true,
            children: []
        )
        let view = FileBrowserSidebarContent(
            rootURL: root,
            tree: state == .populated ? populatedTree : (state == .empty ? emptyTree : nil),
            selectedURL: active,
            isLoading: false,
            errorMessage: state == .error ? "The folder couldn’t be read." : nil,
            highlightActiveFile: true,
            theme: theme,
            onRefresh: {},
            onOpen: { _ in }
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, theme == .dark ? .dark : .light)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed
        }
        return png
    }

    private static func imageDifference(
        expected: Data,
        actual: Data
    ) throws -> (meanChannelDelta: Double, changedPixelFraction: Double) {
        guard let expectedImage = NSBitmapImageRep(data: expected),
              let actualImage = NSBitmapImageRep(data: actual),
              expectedImage.pixelsWide == actualImage.pixelsWide,
              expectedImage.pixelsHigh == actualImage.pixelsHigh else {
            throw SnapshotError.incompatibleImages
        }

        var totalDelta = 0.0
        var changedPixels = 0
        let pixelCount = expectedImage.pixelsWide * expectedImage.pixelsHigh
        for y in 0..<expectedImage.pixelsHigh {
            for x in 0..<expectedImage.pixelsWide {
                guard let expectedColor = expectedImage.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB),
                    let actualColor = actualImage.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else {
                    throw SnapshotError.incompatibleImages
                }
                let delta = (
                    abs(expectedColor.redComponent - actualColor.redComponent)
                    + abs(expectedColor.greenComponent - actualColor.greenComponent)
                    + abs(expectedColor.blueComponent - actualColor.blueComponent)
                ) / 3
                totalDelta += delta
                if delta > 0.10 {
                    changedPixels += 1
                }
            }
        }
        return (
            totalDelta / Double(pixelCount),
            Double(changedPixels) / Double(pixelCount)
        )
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private enum SnapshotError: Error {
        case renderFailed
        case incompatibleImages
    }

    private enum SnapshotState {
        case populated
        case empty
        case error
    }
}
