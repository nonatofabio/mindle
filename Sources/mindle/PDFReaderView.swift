import SwiftUI
import AppKit
import PDFKit

/// Native PDFKit-backed renderer. Mirrors the role `WebReaderView` plays
/// for markdown, but uses Apple's `PDFView` for layout and selection.
/// We deliberately do NOT use PDFKit's built-in annotation system —
/// Mindle annotations live in our own `.mindle.json` sidecar so they
/// flow through the team-collab and agent-MCP pipelines unchanged.
///
/// Stage 1 scope (this file): open + render + scroll + page nav + zoom.
/// Selection capture, highlight overlay, and find-integration land in
/// later stages.
struct PDFReaderView: NSViewRepresentable {
    @EnvironmentObject var store: DocumentStore

    func makeNSView(context: Context) -> FitWidthPDFView {
        let view = FitWidthPDFView()
        // PDFView's autoScales=true tries to fit the page in BOTH
        // dimensions — fine for single-page mode, bad for the
        // continuous-scroll layout we want. With many tall pages stacked
        // vertically inside a wide window, the fit-everything math
        // shrinks each page to a fraction of the visible width. We
        // drive scaleFactor explicitly instead (see applyFitWidth()).
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(store.theme.colors.background)
        // The PDFView itself needs to post frame-change notifications
        // so the subclass's setFrameSize override fires on window resize
        // — otherwise pages would only re-fit when a SwiftUI tick happens
        // to coincide with a layout pass.
        view.postsFrameChangedNotifications = true
        context.coordinator.view = view
        loadDocumentIfNeeded(into: view, context: context)
        view.fontScale = CGFloat(store.fontScale)
        view.applyFitWidth()
        return view
    }

    func updateNSView(_ view: FitWidthPDFView, context: Context) {
        let bg = NSColor(store.theme.colors.background)
        if view.backgroundColor != bg { view.backgroundColor = bg }

        let scale = CGFloat(store.fontScale)
        if abs(view.fontScale - scale) > 0.001 {
            view.fontScale = scale
            view.applyFitWidth()
        }

        loadDocumentIfNeeded(into: view, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadDocumentIfNeeded(into view: FitWidthPDFView, context: Context) {
        guard let url = store.fileURL, url.isFileURL else {
            view.document = nil
            context.coordinator.lastLoadedURL = nil
            return
        }
        if context.coordinator.lastLoadedURL == url { return }
        if let doc = PDFDocument(url: url) {
            view.document = doc
            context.coordinator.lastLoadedURL = url
            // Document loads can outpace the first layout pass — fit-width
            // again now that the page dimensions are known.
            view.applyFitWidth()
        } else {
            view.document = nil
            context.coordinator.lastLoadedURL = nil
        }
    }

    final class Coordinator {
        weak var view: FitWidthPDFView?
        var lastLoadedURL: URL?
    }
}

/// PDFView subclass that keeps pages filling the available width
/// regardless of window size or document. Reads `fontScale` as a
/// multiplier on top of the base fit-width factor so Mindle's
/// ⌘+ / ⌘- shortcut still works as a relative zoom (≈ font scale on
/// Markdown tabs).
final class FitWidthPDFView: PDFView {
    var fontScale: CGFloat = 1.0
    /// Horizontal padding inside the view, in points. Leaves a little
    /// breathing room around the page so it doesn't hit the scrollbar
    /// and doesn't kiss the sidebar's left edge.
    private let horizontalInset: CGFloat = 24

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyFitWidth()
    }

    /// Recompute `scaleFactor` so the first page's media-box width fills
    /// the visible area (minus padding), multiplied by Mindle's font
    /// scale. Idempotent — bails on a sub-percent change so it doesn't
    /// thrash when called from both `updateNSView` and frame-resize.
    func applyFitWidth() {
        guard let doc = document, doc.pageCount > 0,
              let page = doc.page(at: 0) else { return }
        let pageWidth = page.bounds(for: .mediaBox).width
        let available = max(bounds.width - horizontalInset * 2, 1)
        guard pageWidth > 0 else { return }
        let target = (available / pageWidth) * fontScale
        if abs(scaleFactor - target) > 0.005 {
            scaleFactor = target
        }
    }
}
