import SwiftUI
import WebKit
import AppKit
import PDFKit

struct WebReaderView: NSViewRepresentable {
    @EnvironmentObject var store: DocumentStore

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "selectionChanged")
        userContent.add(context.coordinator, name: "annotationClicked")
        userContent.add(context.coordinator, name: "searchResult")
        userContent.add(context.coordinator, name: "diffSetLastSynced")
        userContent.add(context.coordinator, name: "diffSetCurrent")
        userContent.add(context.coordinator, name: "diffAcceptAll")
        userContent.add(context.coordinator, name: "diffRejectAll")
        config.userContentController = userContent
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ImageSchemeHandler.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = false

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.allowsLinkPreview = false
        context.coordinator.web = web

        if let html = readerHTMLURL() {
            let baseDir = html.deletingLastPathComponent()
            web.loadFileURL(html, allowingReadAccessTo: baseDir)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coord = context.coordinator
        guard coord.loaded else { return }

        // Re-render whenever rawText OR lastSyncedText changes — the diff
        // pipeline keys off the pair, so a baseline change has to flow
        // through to the view even when rawText is unchanged.
        if store.rawText != coord.lastSource || store.lastSyncedText != coord.lastSyncedText {
            // Same file, rawText changed → live reload, preserve scroll.
            // Different file (or first load) → fresh load, start at top.
            // Baseline-only change (accept/reject) preserves scroll too.
            let isLiveReload = (coord.lastFileURL == store.fileURL && !coord.lastSource.isEmpty)
            coord.lastSource = store.rawText
            coord.lastSyncedText = store.lastSyncedText
            coord.lastFileURL = store.fileURL
            let baseDir = store.fileURL?.deletingLastPathComponent().path ?? ""
            // mindleLoad's third arg is the diff baseline: when it differs
            // from arg one, the JS layer renders track-changes with chips.
            // Pass null when there's no in-flight diff so the JS hot path
            // skips the diff machinery entirely.
            let baselineLiteral = (store.lastSyncedText == store.rawText)
                ? "null"
                : jsString(store.lastSyncedText)
            web.evaluateJavaScript("window.mindleSetBaseDir(\(jsString(baseDir)));")
            web.evaluateJavaScript("window.mindleLoad(\(jsString(store.rawText)), \(isLiveReload), \(baselineLiteral));")
        }

        if store.theme.rawValue != coord.lastTheme {
            coord.lastTheme = store.theme.rawValue
            web.evaluateJavaScript("window.mindleSetTheme(\(jsString(store.theme.rawValue)));")
        }

        if store.fontScale != coord.lastFontScale {
            coord.lastFontScale = store.fontScale
            web.evaluateJavaScript("window.mindleSetFontScale(\(store.fontScale));")
        }

        if store.readingWidth.rawValue != coord.lastReadingWidth {
            coord.lastReadingWidth = store.readingWidth.rawValue
            web.evaluateJavaScript("window.mindleSetReadingWidth(\(jsString(store.readingWidth.rawValue)));")
        }

        if store.readingFont.rawValue != coord.lastReadingFont {
            coord.lastReadingFont = store.readingFont.rawValue
            web.evaluateJavaScript("window.mindleSetReadingFont(\(jsString(store.readingFont.rawValue)));")
        }

        if store.bionicText != coord.lastBionicText {
            coord.lastBionicText = store.bionicText
            web.evaluateJavaScript("window.mindleSetBionicText(\(store.bionicText ? "true" : "false"));")
        }

        if store.annotations != coord.lastAnnotations {
            coord.lastAnnotations = store.annotations
            let payload = store.annotations.map { a -> [String: Any] in
                let color = store.collaborators[a.author ?? ""]?.color ?? "#FFD700"
                return [
                    "id": a.id.uuidString,
                    "text": a.text,
                    "prefix": a.prefix,
                    "suffix": a.suffix,
                    "note": a.note,
                    "color": color
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                web.evaluateJavaScript("window.mindleSetAnnotations(\(json));")
            }
        }

        if let id = store.focusedAnnotation, id != coord.lastFocusID {
            coord.lastFocusID = id
            web.evaluateJavaScript("window.mindleFocusAnnotation(\(jsString(id.uuidString)));")
        }

        let effectiveQuery = store.showSearch ? store.searchQuery : ""
        if effectiveQuery != coord.lastSearchQuery {
            coord.lastSearchQuery = effectiveQuery
            web.evaluateJavaScript("window.mindleSearch(\(jsString(effectiveQuery)));")
        }

        if let t = store.searchNextRequestedAt, t != coord.lastSearchNextAt {
            coord.lastSearchNextAt = t
            web.evaluateJavaScript("window.mindleSearchNext();")
        }

        if let t = store.searchPrevRequestedAt, t != coord.lastSearchPrevAt {
            coord.lastSearchPrevAt = t
            web.evaluateJavaScript("window.mindleSearchPrev();")
        }

        if let t = store.pdfExportRequestedAt, t != coord.lastPDFExportAt {
            coord.lastPDFExportAt = t
            coord.runPDFExport()
        }

        if let t = store.highlightRequestedAt, t != coord.lastHighlightAt {
            coord.lastHighlightAt = t
            coord.fetchLiveSelection(web: web) { text, prefix, suffix in
                self.store.applyHighlight(text: text, prefix: prefix, suffix: suffix)
            }
        }

        if let t = store.noteRequestedAt, t != coord.lastNoteAt {
            coord.lastNoteAt = t
            coord.fetchLiveSelection(web: web) { text, prefix, suffix in
                self.store.applyNote(text: text, prefix: prefix, suffix: suffix)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: WebReaderView
        weak var web: WKWebView?
        var loaded = false

        // Track last-sent values to avoid redundant pushes
        var lastSource: String = ""
        var lastSyncedText: String = ""
        var lastFileURL: URL?
        var lastTheme: String = ""
        var lastFontScale: Double = 0
        var lastReadingWidth: String = ""
        var lastReadingFont: String = ""
        var lastBionicText: Bool? = nil
        var lastAnnotations: [Annotation] = []
        var lastFocusID: UUID?
        var lastSearchQuery: String = ""
        var lastSearchNextAt: Date?
        var lastSearchPrevAt: Date?
        var lastPDFExportAt: Date?
        var lastHighlightAt: Date?
        var lastNoteAt: Date?

        init(_ p: WebReaderView) { parent = p }

        /// Pull the current selection straight out of JS, bypassing the
        /// debounced `selectionChanged` cache. Used by ⌘⇧H / ⌘⇧N so the
        /// hotkeys can't fire against a stale selection state.
        func fetchLiveSelection(web: WKWebView, completion: @escaping (String, String, String) -> Void) {
            web.evaluateJavaScript("window.mindleCaptureSelectionNow();") { result, _ in
                let body = result as? [String: Any] ?? [:]
                let text = (body["text"] as? String) ?? ""
                let prefix = (body["prefix"] as? String) ?? ""
                let suffix = (body["suffix"] as? String) ?? ""
                Task { @MainActor in
                    completion(text, prefix, suffix)
                }
            }
        }

        // US Letter in points — WKWebView's createPDF measures in pt (1 px = 1 pt).
        static let pdfPageWidth: CGFloat = 612
        static let pdfPageHeight: CGFloat = 792

        func runPDFExport() {
            guard let web = self.web else { NSSound.beep(); return }

            let panel = NSSavePanel()
            panel.title = "Export PDF"
            panel.allowedContentTypes = [.pdf]
            let baseName = parent.store.fileURL?
                .deletingPathExtension()
                .lastPathComponent ?? "Mindle"
            panel.nameFieldStringValue = "\(baseName).pdf"
            guard panel.runModal() == .OK, let destURL = panel.url else { return }

            // Flip to print-mode CSS (constrains body to 612pt) and read
            // the resulting scrollHeight so we know how many Letter-sized
            // pages to capture.
            web.evaluateJavaScript("window.mindleBeginPDFExport();") { [weak self] result, _ in
                guard let self, let web = self.web else { return }

                let totalHeight = (result as? CGFloat) ?? Self.pdfPageHeight
                let pageCount = max(1, Int(ceil(totalHeight / Self.pdfPageHeight)))

                self.capturePages(
                    web: web,
                    remaining: pageCount,
                    pageIndex: 0,
                    pageCount: pageCount,
                    document: PDFDocument(),
                    destination: destURL
                )
            }
        }

        private func capturePages(
            web: WKWebView,
            remaining: Int,
            pageIndex: Int,
            pageCount: Int,
            document: PDFDocument,
            destination: URL
        ) {
            if remaining == 0 {
                // Done: restore screen styling, then write the stitched PDF.
                web.evaluateJavaScript("window.mindleEndPDFExport();", completionHandler: nil)
                if let data = document.dataRepresentation() {
                    do {
                        try data.write(to: destination, options: .atomic)
                    } catch {
                        NSSound.beep()
                    }
                } else {
                    NSSound.beep()
                }
                return
            }

            let config = WKPDFConfiguration()
            config.rect = CGRect(
                x: 0,
                y: CGFloat(pageIndex) * Self.pdfPageHeight,
                width: Self.pdfPageWidth,
                height: Self.pdfPageHeight
            )

            web.createPDF(configuration: config) { [weak self] result in
                guard let self else { return }
                if case .success(let data) = result,
                   let pdf = PDFDocument(data: data),
                   let page = pdf.page(at: 0) {
                    document.insert(page, at: document.pageCount)
                }
                self.capturePages(
                    web: web,
                    remaining: remaining - 1,
                    pageIndex: pageIndex + 1,
                    pageCount: pageCount,
                    document: document,
                    destination: destination
                )
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            // Force initial flush by clearing tracked state
            lastSource = ""
            lastSyncedText = ""
            lastFileURL = nil
            lastTheme = ""
            lastFontScale = 0
            lastReadingWidth = ""
            lastReadingFont = ""
            lastBionicText = nil
            lastAnnotations = []
            lastFocusID = nil
            // Trigger SwiftUI to call updateNSView
            DispatchQueue.main.async {
                self.parent.store.objectWillChange.send()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, action.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "selectionChanged":
                guard let body = message.body as? [String: Any] else { return }
                let text = (body["text"] as? String) ?? ""
                let prefix = (body["prefix"] as? String) ?? ""
                let suffix = (body["suffix"] as? String) ?? ""
                Task { @MainActor in
                    self.parent.store.updateSelection(text: text, prefix: prefix, suffix: suffix)
                }

            case "annotationClicked":
                guard let body = message.body as? [String: Any],
                      let idStr = body["id"] as? String,
                      let id = UUID(uuidString: idStr) else { return }
                Task { @MainActor in
                    self.parent.store.focusedAnnotation = id
                    self.parent.store.editingAnnotationID = id
                    self.parent.store.showAnnotations = true
                }

            case "searchResult":
                guard let body = message.body as? [String: Any] else { return }
                let total = (body["total"] as? Int) ?? 0
                let current = (body["current"] as? Int) ?? 0
                Task { @MainActor in
                    self.parent.store.updateSearchResult(total: total, current: current)
                }

            case "diffSetLastSynced":
                // Per-chunk accept: JS computed a new baseline incorporating
                // the chunk's "after" content. Swift just stores it; the
                // re-render shows the now-shrunk diff.
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String else { return }
                Task { @MainActor in
                    self.parent.store.setLastSyncedText(text)
                }

            case "diffSetCurrent":
                // Per-chunk reject: JS computed a new current text where
                // the chunk's "after" was reverted to the baseline's
                // "before". Swift writes that through to disk.
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String else { return }
                Task { @MainActor in
                    self.parent.store.setRawText(text)
                }

            case "diffAcceptAll":
                Task { @MainActor in
                    self.parent.store.acceptAllChanges()
                }

            case "diffRejectAll":
                Task { @MainActor in
                    self.parent.store.rejectAllChanges()
                }

            default: break
            }
        }
    }

    private func readerHTMLURL() -> URL? {
        if let resURL = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "web") {
            return resURL
        }
        if let resDir = Bundle.main.resourceURL {
            let alt = resDir.appendingPathComponent("web/reader.html")
            if FileManager.default.fileExists(atPath: alt.path) { return alt }
        }
        return nil
    }
}

private func jsString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
    if let data = data, let str = String(data: data, encoding: .utf8) {
        if str.hasPrefix("["), str.hasSuffix("]") {
            return String(str.dropFirst().dropLast())
        }
    }
    return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
}
