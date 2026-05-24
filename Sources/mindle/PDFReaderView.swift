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
        view.applyFitWidth()

        // Bridge PDFView's live selection into the store so the toolbar's
        // highlight / note buttons (which gate on `store.hasSelection`)
        // enable as soon as the user drags a selection. Without this hook,
        // hasSelection only ever flips via the JS path used by Markdown
        // tabs — so on a PDF tab the toolbar buttons stay greyed out and
        // the user has to fall back to ⌘⇧H or the sidebar + button.
        // prefix/suffix stay empty here — the highlight pipeline on PDFs
        // does its own anchor extraction via captureCurrentSelection,
        // reading PDFPage.string directly.
        let store = self.store
        context.coordinator.selectionObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged,
            object: view,
            queue: .main
        ) { [weak store] note in
            // NotificationCenter runs the closure on the queue we passed
            // (.main), but the compiler treats it as nonisolated and the
            // call into @MainActor DocumentStore would otherwise be an
            // implicit async hop. assumeIsolated tells the runtime we're
            // already on the main actor — zero overhead, fails fast in
            // the impossible case that the queue ever changes.
            MainActor.assumeIsolated {
                guard let store, let pv = note.object as? PDFView else { return }
                let text = pv.currentSelection?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                store.updateSelection(text: text, prefix: "", suffix: "")
            }
        }
        return view
    }

    static func dismantleNSView(_ nsView: FitWidthPDFView, coordinator: Coordinator) {
        if let token = coordinator.selectionObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.selectionObserver = nil
        }
    }

    func updateNSView(_ view: FitWidthPDFView, context: Context) {
        let bg = NSColor(store.theme.colors.background)
        if view.backgroundColor != bg { view.backgroundColor = bg }

        let scale = CGFloat(store.fontScale)
        if abs(context.coordinator.lastFontScale - scale) > 0.001 {
            if context.coordinator.lastFontScale > 0 {
                if scale > context.coordinator.lastFontScale {
                    view.zoomIn(nil)
                } else if scale < context.coordinator.lastFontScale {
                    view.zoomOut(nil)
                }
            }
            context.coordinator.lastFontScale = scale
        }

        if let t = store.pdfFitWidthRequestedAt,
           t != context.coordinator.lastFitWidthAt {
            context.coordinator.lastFitWidthAt = t
            view.resetToFitWidth()
        }

        loadDocumentIfNeeded(into: view, context: context)

        // Highlight / Note request handlers — capture the live PDFSelection,
        // build the anchor, and hand off to the store. The store creates
        // the Annotation, the next updateNSView tick re-syncs overlays.
        if let t = store.highlightRequestedAt,
           t != context.coordinator.lastHighlightAt {
            context.coordinator.lastHighlightAt = t
            if let anchor = captureCurrentSelection(view: view) {
                store.applyHighlight(
                    text: anchor.text,
                    prefix: anchor.prefix,
                    suffix: anchor.suffix,
                    pageIndex: anchor.pageIndex,
                    pageTextHash: anchor.pageTextHash
                )
            } else {
                NSSound.beep()
            }
        }

        if let t = store.noteRequestedAt,
           t != context.coordinator.lastNoteAt {
            context.coordinator.lastNoteAt = t
            if let anchor = captureCurrentSelection(view: view) {
                store.applyNote(
                    text: anchor.text,
                    prefix: anchor.prefix,
                    suffix: anchor.suffix,
                    pageIndex: anchor.pageIndex,
                    pageTextHash: anchor.pageTextHash
                )
            } else {
                NSSound.beep()
            }
        }

        // Re-sync our highlight overlays whenever the annotation set
        // changes. Cheap when nothing changed (skipped by the array
        // equality check below).
        if store.annotations != context.coordinator.lastAnnotations {
            context.coordinator.lastAnnotations = store.annotations
            syncHighlightOverlays(view: view)
        }

        // Sidebar's "jump to this passage" button sets focusedAnnotation.
        // WebReaderView observes it for Markdown; on PDF we need to
        // navigate the PDFView to the right page and, when we can resolve
        // a PDFSelection, scroll the selection's rect into view. Same
        // single-change trigger pattern as the other signals on this
        // coordinator.
        if let focusID = store.focusedAnnotation,
           focusID != context.coordinator.lastFocusID {
            context.coordinator.lastFocusID = focusID
            scrollTo(annotationID: focusID, view: view)
        }

        // Search wiring. When the bar is hidden we feed an empty query
        // through the same path so highlightedSelections gets cleared
        // on close. Next/Prev signals from the bar step the current
        // match cursor.
        let effectiveQuery = store.showSearch ? store.searchQuery : ""
        if effectiveQuery != context.coordinator.lastSearchQuery {
            context.coordinator.lastSearchQuery = effectiveQuery
            performPDFSearch(query: effectiveQuery, view: view, coordinator: context.coordinator)
        }
        if let t = store.searchNextRequestedAt,
           t != context.coordinator.lastSearchNextAt {
            context.coordinator.lastSearchNextAt = t
            stepPDFSearch(by: 1, view: view, coordinator: context.coordinator)
        }
        if let t = store.searchPrevRequestedAt,
           t != context.coordinator.lastSearchPrevAt {
            context.coordinator.lastSearchPrevAt = t
            stepPDFSearch(by: -1, view: view, coordinator: context.coordinator)
        }
    }

    // MARK: - Find

    /// Run a fresh PDFDocument.findString for `query`, push matches into
    /// the view's highlightedSelections (yellow per page), set the first
    /// match as currentSelection (PDFView paints that one darker), and
    /// scroll it into view. Mirrors the markdown side's behaviour: empty
    /// query → clear everything; no matches → highlightedSelections=nil
    /// and total/current=0; matches → first one becomes current.
    @MainActor
    private func performPDFSearch(query: String, view: FitWidthPDFView, coordinator: Coordinator) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            view.highlightedSelections = nil
            view.setCurrentSelection(nil, animate: false)
            coordinator.searchMatches = []
            coordinator.searchCurrentIdx = 0
            store.updateSearchResult(total: 0, current: 0)
            return
        }
        guard let doc = view.document else {
            store.updateSearchResult(total: 0, current: 0)
            return
        }
        let matches = doc.findString(trimmed, withOptions: .caseInsensitive)
        coordinator.searchMatches = matches
        if matches.isEmpty {
            view.highlightedSelections = nil
            view.setCurrentSelection(nil, animate: false)
            coordinator.searchCurrentIdx = 0
            store.updateSearchResult(total: 0, current: 0)
            return
        }
        view.highlightedSelections = matches
        coordinator.searchCurrentIdx = 0
        view.setCurrentSelection(matches[0], animate: false)
        view.go(to: matches[0])
        store.updateSearchResult(total: matches.count, current: 1)
    }

    /// Step the current search match by `step` (+1 next, -1 prev) with
    /// wrap-around. Updates view.currentSelection + scrolls to it, and
    /// reports the new 1-based position to the search bar via
    /// updateSearchResult.
    @MainActor
    private func stepPDFSearch(by step: Int, view: FitWidthPDFView, coordinator: Coordinator) {
        let count = coordinator.searchMatches.count
        guard count > 0 else { return }
        let next = ((coordinator.searchCurrentIdx + step) % count + count) % count
        coordinator.searchCurrentIdx = next
        let match = coordinator.searchMatches[next]
        view.setCurrentSelection(match, animate: true)
        view.go(to: match)
        store.updateSearchResult(total: count, current: next + 1)
    }

    /// Find the annotation by id, navigate the PDFView to its page, and
    /// scroll its first line into view if the anchor still resolves.
    /// Falls back to page-level navigation when re-anchor fails.
    @MainActor
    private func scrollTo(annotationID id: UUID, view: FitWidthPDFView) {
        guard let ann = store.annotations.first(where: { $0.id == id }),
              let pageIdx = ann.pageIndex,
              let doc = view.document,
              pageIdx >= 0, pageIdx < doc.pageCount,
              let page = doc.page(at: pageIdx) else { return }
        // Prefer scrolling to the exact selection rect when the anchor
        // re-resolves cleanly; otherwise land on the page so the user
        // at least sees the right region.
        if let pageText = page.string,
           let range = Self.findAnchorRange(for: ann, in: pageText) {
            let nsRange = NSRange(range, in: pageText)
            if let sel = page.selection(for: nsRange) {
                view.go(to: sel)
                return
            }
        }
        view.go(to: page)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Inspect the freshly loaded PDFDocument and surface a banner-worthy
    /// status to the store. `.locked` for password-protected docs (PDFView
    /// renders blank pages and selection does nothing). `.noExtractableText`
    /// for scanned PDFs with no OCR layer — the image renders fine, the
    /// user just can't highlight anything. `.ok` otherwise; the banner
    /// stays hidden.
    @MainActor
    private func publishStatus(for doc: PDFDocument) {
        if doc.isLocked {
            store.pdfStatus = .locked
            return
        }
        // Probe up to the first 5 pages — enough signal to distinguish a
        // scanned image PDF from a normal text PDF without paying to
        // extract every page of a large document. >20 trimmed chars on
        // any page is plenty to call it text-bearing.
        var hasText = false
        let probeCount = min(doc.pageCount, 5)
        for i in 0..<probeCount {
            if let page = doc.page(at: i),
               let s = page.string,
               s.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
                hasText = true
                break
            }
        }
        store.pdfStatus = hasText ? .ok : .noExtractableText
    }

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
            publishStatus(for: doc)
        } else {
            view.document = nil
            context.coordinator.lastLoadedURL = nil
            store.pdfStatus = .unloadable
        }
    }

    final class Coordinator {
        weak var view: FitWidthPDFView?
        var lastLoadedURL: URL?
        var lastFontScale: CGFloat = 0
        var lastFitWidthAt: Date?
        var lastHighlightAt: Date?
        var lastNoteAt: Date?
        var lastAnnotations: [Annotation] = []
        var lastFocusID: UUID?
        var lastSearchQuery: String = ""
        var lastSearchNextAt: Date?
        var lastSearchPrevAt: Date?
        var searchMatches: [PDFSelection] = []
        var searchCurrentIdx: Int = 0
        /// NotificationCenter token for the PDFView selection bridge.
        /// Removed in dismantleNSView so we don't leak observers across
        /// SwiftUI's recreation of the representable.
        var selectionObserver: NSObjectProtocol?
    }

    // MARK: - Selection capture

    /// Read the current PDFSelection from the view and translate it into
    /// Mindle's text+prefix+suffix anchor format, augmented with the page
    /// index and a hash of the page's full extracted text (for drift
    /// detection on reopen).
    ///
    /// Anchor offsets use a literal `range(of:)` search on the page text.
    /// PDF column layouts can introduce line breaks inside the selection
    /// that don't appear in PDFPage.string the same way — when that
    /// happens, this returns nil and the caller beeps. Stage 3 will add
    /// a whitespace-normalised fallback search; for v3.0-rc1, the
    /// arxiv-style single-column case has to work first.
    private func captureCurrentSelection(view: FitWidthPDFView)
        -> (text: String, prefix: String, suffix: String, pageIndex: Int, pageTextHash: String)?
    {
        guard let selection = view.currentSelection,
              let firstPage = selection.pages.first,
              let pageText = firstPage.string,
              let doc = view.document else { return nil }
        let raw = selection.string ?? ""
        let selectedText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return nil }
        guard let range = pageText.range(of: selectedText) else { return nil }

        // Take up to 32 chars before / after the matched span. The
        // existing anchor convention on Markdown uses ~32 chars each
        // side; matching it keeps re-anchor heuristics cross-format.
        let prefixStartOffset = max(0, pageText.distance(from: pageText.startIndex, to: range.lowerBound) - 32)
        let suffixEndOffset = min(
            pageText.count,
            pageText.distance(from: pageText.startIndex, to: range.upperBound) + 32
        )
        let prefixStart = pageText.index(pageText.startIndex, offsetBy: prefixStartOffset)
        let suffixEnd = pageText.index(pageText.startIndex, offsetBy: suffixEndOffset)
        let prefix = String(pageText[prefixStart..<range.lowerBound])
        let suffix = String(pageText[range.upperBound..<suffixEnd])

        let pageIndex = doc.index(for: firstPage)
        let pageTextHash = DocumentStore.contentHash(pageText)
        return (selectedText, prefix, suffix, pageIndex, pageTextHash)
    }

    // MARK: - Anchor lookup

    /// Re-anchor an existing PDF annotation against the current
    /// extracted page text. Two passes:
    ///
    /// 1. **Literal `range(of:)`** — the happy path. Works whenever the
    ///    page extracts identically to when the annotation was captured.
    /// 2. **Flexible-whitespace regex** — when the literal misses we
    ///    rebuild the target as a pattern that treats each whitespace
    ///    run as `\s+`, so the same selection found across a column wrap
    ///    or hyphenation boundary still matches. Skipped when
    ///    `pageTextHash` matches the stored value (extraction is
    ///    identical → literal already failed for some other reason, no
    ///    point spending the regex compile).
    ///
    /// Returns nil when neither pass finds the anchor. The caller (the
    /// overlay-sync loop) simply skips drawing in that case — the
    /// annotation remains in the sidebar but has no visible highlight on
    /// the page until a later doc edit puts the text back. Stage 6 will
    /// add an "orphaned" UI cue.
    static func findAnchorRange(for ann: Annotation, in pageText: String) -> Range<String.Index>? {
        bestAnchor(for: ann, in: pageText)?.range
    }

    /// Same as `findAnchorRange` but also returns a confidence score so
    /// callers (notably `resolvePDFAnchor` doing cross-page search) can
    /// compare candidates across pages and pick the one whose neighborhood
    /// best matches the stored prefix/suffix. The score is the number of
    /// chars that match between actual + stored prefix (tail-aligned —
    /// because prefix is what comes *before* the anchor) plus the same
    /// for suffix (head-aligned). When neither prefix nor suffix is set,
    /// every match scores 0 and first-on-page wins.
    static func bestAnchor(for ann: Annotation, in pageText: String) -> (range: Range<String.Index>, score: Int)? {
        // Pass 1: literal. Enumerate every occurrence, score each.
        var candidates: [Range<String.Index>] = []
        var searchFrom = pageText.startIndex
        while let r = pageText.range(of: ann.text, range: searchFrom..<pageText.endIndex) {
            candidates.append(r)
            // Step past one char of the match so overlapping occurrences
            // don't get missed but we don't infinite-loop on empty text.
            searchFrom = pageText.index(after: r.lowerBound)
        }
        if let best = pickBest(candidates, in: pageText, annotation: ann) {
            return best
        }
        // Pass 2: flex whitespace, only when the page extracted
        // identically to creation time is *not* the case (otherwise the
        // literal miss is real drift, not whitespace shuffle).
        if let storedHash = ann.pageTextHash,
           storedHash == DocumentStore.contentHash(pageText) {
            return nil
        }
        guard let flexRange = flexibleWhitespaceRange(target: ann.text, in: pageText) else {
            return nil
        }
        let score = neighborhoodScore(range: flexRange, in: pageText, annotation: ann)
        return (flexRange, score)
    }

    private static func pickBest(
        _ ranges: [Range<String.Index>],
        in pageText: String,
        annotation ann: Annotation
    ) -> (range: Range<String.Index>, score: Int)? {
        guard !ranges.isEmpty else { return nil }
        if ranges.count == 1 {
            let r = ranges[0]
            return (r, neighborhoodScore(range: r, in: pageText, annotation: ann))
        }
        var best: (range: Range<String.Index>, score: Int)?
        for r in ranges {
            let s = neighborhoodScore(range: r, in: pageText, annotation: ann)
            if best == nil || s > best!.score {
                best = (r, s)
            }
        }
        return best
    }

    /// Score a candidate range by how well its real prefix/suffix
    /// neighborhood matches the annotation's stored prefix/suffix.
    /// Prefix is tail-aligned (chars immediately *before* the match);
    /// suffix is head-aligned (chars immediately *after*). Score is the
    /// sum of matching-char counts on each side. Empty stored prefix /
    /// suffix score 0 — single-match cases and ambiguous cases without
    /// disambiguating context end up at 0 and the caller still picks the
    /// first candidate consistently.
    private static func neighborhoodScore(
        range: Range<String.Index>,
        in pageText: String,
        annotation ann: Annotation
    ) -> Int {
        var score = 0
        if !ann.prefix.isEmpty {
            let lo = pageText.startIndex
            // Take up to ann.prefix.count chars immediately before the match.
            let want = ann.prefix.count
            let dist = pageText.distance(from: lo, to: range.lowerBound)
            let take = min(want, dist)
            let actualStart = pageText.index(range.lowerBound, offsetBy: -take)
            let actualPrefix = String(pageText[actualStart..<range.lowerBound])
            score += tailMatchCount(actualPrefix, ann.prefix)
        }
        if !ann.suffix.isEmpty {
            let hi = pageText.endIndex
            let want = ann.suffix.count
            let dist = pageText.distance(from: range.upperBound, to: hi)
            let take = min(want, dist)
            let actualEnd = pageText.index(range.upperBound, offsetBy: take)
            let actualSuffix = String(pageText[range.upperBound..<actualEnd])
            score += headMatchCount(actualSuffix, ann.suffix)
        }
        return score
    }

    /// Count of consecutive matching chars from the END of both strings.
    private static func tailMatchCount(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        var n = 0
        while n < ac.count && n < bc.count && ac[ac.count - 1 - n] == bc[bc.count - 1 - n] {
            n += 1
        }
        return n
    }

    /// Count of consecutive matching chars from the START of both strings.
    private static func headMatchCount(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        var n = 0
        while n < ac.count && n < bc.count && ac[n] == bc[n] {
            n += 1
        }
        return n
    }

    private static func flexibleWhitespaceRange(target: String, in pageText: String) -> Range<String.Index>? {
        guard !target.isEmpty else { return nil }
        var pattern = ""
        var inWhitespace = false
        for ch in target {
            if ch.isWhitespace {
                if !inWhitespace {
                    pattern += "\\s+"
                    inWhitespace = true
                }
            } else {
                inWhitespace = false
                pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let ns = pageText as NSString
        guard let match = re.firstMatch(
            in: pageText,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        return Range(match.range, in: pageText)
    }

    // MARK: - Highlight overlays

    /// Sync visible highlight rectangles on the PDF with the current
    /// `store.annotations`. Removes any prior Mindle overlays (identified
    /// by the `MindleHighlightAnnotation` subclass) and re-adds one per
    /// active annotation. PDFKit-native annotations baked into the PDF
    /// file itself are left alone — we identify ours by subclass, not by
    /// type.
    @MainActor
    private func syncHighlightOverlays(view: FitWidthPDFView) {
        guard let doc = view.document else { return }
        // Sweep existing overlays first.
        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx) else { continue }
            for existing in page.annotations where existing is MindleHighlightAnnotation {
                page.removeAnnotation(existing)
            }
        }
        // Re-draw, collecting any annotations that couldn't be anchored
        // so the sidebar card can surface a drift indicator.
        var orphans: Set<UUID> = []
        for ann in store.annotations {
            guard let pageIdx = ann.pageIndex,
                  pageIdx >= 0, pageIdx < doc.pageCount,
                  let page = doc.page(at: pageIdx),
                  let pageText = page.string else {
                orphans.insert(ann.id)
                continue
            }
            guard let range = Self.findAnchorRange(for: ann, in: pageText) else {
                orphans.insert(ann.id)
                continue
            }
            let nsRange = NSRange(range, in: pageText)
            guard let sel = page.selection(for: nsRange) else {
                orphans.insert(ann.id)
                continue
            }
            let color = highlightColor(for: ann)
            for lineSel in sel.selectionsByLine() {
                let bounds = lineSel.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let overlay = MindleHighlightAnnotation(
                    bounds: bounds,
                    forType: .highlight,
                    withProperties: nil
                )
                overlay.color = color
                page.addAnnotation(overlay)
            }
        }
        if store.orphanedAnnotations != orphans {
            store.orphanedAnnotations = orphans
        }
    }

    /// Pick the highlight color for a PDF annotation. Agents get the
    /// theme's muted color (distinct from human highlights), humans get
    /// their collaborator-registry color when one is set, otherwise the
    /// theme's highlight color. Mirrors the Markdown `authorColor`
    /// helper philosophy.
    @MainActor
    private func highlightColor(for ann: Annotation) -> NSColor {
        let c = store.theme.colors
        if ann.author == "agent" {
            return NSColor(c.muted).withAlphaComponent(0.4)
        }
        if let alias = ann.author,
           alias != "user",
           let hex = store.collaborators[alias]?.color {
            return NSColor(Color(hex: hex)).withAlphaComponent(0.4)
        }
        return NSColor(c.highlight).withAlphaComponent(0.4)
    }
}

/// PDFAnnotation subclass used solely as a marker — lets `syncHighlightOverlays`
/// distinguish Mindle's overlays from any annotations baked into the PDF
/// file itself, so we can sweep ours without touching theirs.
final class MindleHighlightAnnotation: PDFAnnotation {}

/// PDFView subclass that keeps pages filling the available width on
/// window resize *unless* the user has manually zoomed. Without the
/// override flag the user's pinch/⌘+ would be reverted every time the
/// view re-laid out (and we lay out a lot).
///
/// `fontScale` is no longer used as a zoom multiplier — PDF zoom now
/// lives entirely in PDFKit's scaleFactor, modified by the user
/// directly. Mindle's ⌘+ / ⌘- on PDF tabs routes through
/// `view.zoomIn() / view.zoomOut()` (the native PDFKit step) rather
/// than the Markdown-only fontScale path.
final class FitWidthPDFView: PDFView {
    /// Set to true when the *user* (not Mindle) has driven scaleFactor —
    /// pinch-to-zoom, the native ⌘+/⌘- on PDFView, or the explicit
    /// menu zoom actions we wire below. While set, `applyFitWidth()` is
    /// a no-op so the user's zoom sticks across window resizes. The
    /// "Fit Width" menu action clears it.
    private(set) var userOverridesFit: Bool = false
    private var applyingFitWidth: Bool = false
    /// Horizontal padding inside the view, in points. Leaves a little
    /// breathing room around the page so it doesn't hit the scrollbar
    /// and doesn't kiss the sidebar's left edge.
    private let horizontalInset: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wireScaleObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wireScaleObserver()
    }

    private func wireScaleObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scaleChanged),
            name: .PDFViewScaleChanged,
            object: self
        )
    }

    @objc private func scaleChanged() {
        if !applyingFitWidth {
            userOverridesFit = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !userOverridesFit {
            applyFitWidth()
        }
    }

    /// Recompute `scaleFactor` so the first page's media-box width fills
    /// the visible area (minus padding). Idempotent — bails on a
    /// sub-percent change so it doesn't thrash when called from both
    /// `updateNSView` and frame-resize.
    func applyFitWidth() {
        guard let doc = document, doc.pageCount > 0,
              let page = doc.page(at: 0) else { return }
        let pageWidth = page.bounds(for: .mediaBox).width
        let available = max(bounds.width - horizontalInset * 2, 1)
        guard pageWidth > 0 else { return }
        let target = available / pageWidth
        if abs(scaleFactor - target) > 0.005 {
            applyingFitWidth = true
            scaleFactor = target
            applyingFitWidth = false
        }
    }

    /// Menu-action target: drop the user-override flag and re-fit.
    func resetToFitWidth() {
        userOverridesFit = false
        applyFitWidth()
    }
}
