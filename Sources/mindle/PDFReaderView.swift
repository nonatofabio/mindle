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

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        // Continuous single-column scroll — matches the "long markdown
        // document" feel and lets a page-spanning selection work as one
        // unit. Two-up / facing-pages can come later if asked for.
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(store.theme.colors.background)
        context.coordinator.view = view
        loadDocumentIfNeeded(into: view, context: context)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Theme background flips so the PDF sits on the same color as the
        // rest of the reader pane — the PDF page itself keeps its own
        // colors (no tinting; that decision is in the v3.0 scope doc).
        let bg = NSColor(store.theme.colors.background)
        if view.backgroundColor != bg { view.backgroundColor = bg }

        // Font-scale maps to PDFKit zoom. The map is approximate — Mindle's
        // font scale runs 0.75 → 1.6, PDFKit zoom is a multiplier on its
        // own "scale factor for size to fit." 1.0 = fit-to-width.
        let targetScale = CGFloat(store.fontScale)
        if abs(view.scaleFactor - targetScale * view.scaleFactorForSizeToFit) > 0.005 {
            view.scaleFactor = targetScale * view.scaleFactorForSizeToFit
        }

        loadDocumentIfNeeded(into: view, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Compares the URL the view is currently displaying against
    /// `store.fileURL` and reloads when they diverge. Avoids re-loading
    /// the same document on every SwiftUI tick (which would reset the
    /// user's scroll position).
    private func loadDocumentIfNeeded(into view: PDFView, context: Context) {
        guard let url = store.fileURL, url.isFileURL else {
            view.document = nil
            context.coordinator.lastLoadedURL = nil
            return
        }
        if context.coordinator.lastLoadedURL == url { return }
        if let doc = PDFDocument(url: url) {
            view.document = doc
            context.coordinator.lastLoadedURL = url
        } else {
            view.document = nil
            context.coordinator.lastLoadedURL = nil
        }
    }

    final class Coordinator {
        weak var view: PDFView?
        var lastLoadedURL: URL?
    }
}
