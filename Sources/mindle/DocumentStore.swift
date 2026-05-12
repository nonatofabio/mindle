import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ReaderTheme: String, CaseIterable, Codable {
    case light, sepia, dark
}

/// A message in an annotation's thread. Threads are how the user and
/// the agent have a back-and-forth about a passage — the agent can
/// post progress notes or questions, the user can reply, all anchored
/// to the same passage.
struct AnnotationMessage: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// "user" or "agent". Future authors (e.g., "system") can be added
    /// without breaking the codec; readers should treat unknown values
    /// as user.
    var author: String
    var text: String
    var createdAt: Date = Date()
}

struct Annotation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String        // the selected passage verbatim
    var prefix: String      // ~32 chars before
    var suffix: String      // ~32 chars after
    var note: String
    var createdAt: Date = Date()
    /// nil means user-created — the default for every annotation made
    /// before threads existed. Agent-created annotations get "agent"
    /// so the UI can mark them distinctly.
    var author: String?
    /// Optional follow-up messages. Stored nil (not []) when there are
    /// no replies so existing sidecars round-trip without growth and
    /// the JSON stays minimal for the common case.
    var thread: [AnnotationMessage]?
}

struct FileNode: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [FileNode]?   // nil = leaf file; non-nil = directory
}

/// One open document inside a window. Active-tab state still lives in
/// the window-scoped @Published vars (`fileURL`, `rawText`, `annotations`,
/// `lastSyncedText`) so all existing features keep working untouched;
/// inactive tabs are snapshotted here and rehydrated on activate.
struct DocumentTab: Identifiable, Equatable {
    let id: UUID
    var fileURL: URL
    var rawText: String
    var annotations: [Annotation]
    /// Baseline against which diff-on-reload compares. Equals `rawText`
    /// when there are no in-flight external edits. When an external write
    /// updates `rawText`, this stays at the previously-reviewed version
    /// until the user accepts the change.
    var lastSyncedText: String
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var fileURL: URL?
    @Published var rawText: String = ""
    @Published var annotations: [Annotation] = []
    /// Baseline for diff-on-reload. When `lastSyncedText != rawText`, the
    /// reader view shows track-changes between the two. Accepting clears
    /// the diff (lastSyncedText := rawText); rejecting reverts the
    /// document on disk (rawText := lastSyncedText, written through).
    @Published var lastSyncedText: String = ""

    @Published var theme: ReaderTheme = .sepia
    @Published var fontScale: Double = 1.0
    @Published var showAnnotations: Bool = false
    @Published var showFileBrowser: Bool = false
    @Published var fileTree: FileNode? = nil

    // Tabs (per-window). Empty when no document is open; otherwise the active
    // tab's state mirrors `fileURL` / `rawText` / `annotations` above.
    @Published var tabs: [DocumentTab] = []
    @Published var activeTabID: UUID? = nil

    // Search
    @Published var showSearch: Bool = false
    @Published var searchQuery: String = ""
    @Published private(set) var searchTotal: Int = 0
    @Published private(set) var searchCurrent: Int = 0   // 1-based; 0 = no active match
    @Published var searchNextRequestedAt: Date? = nil
    @Published var searchPrevRequestedAt: Date? = nil

    // Selection from the web view
    @Published private(set) var selectionText: String = ""
    private var selectionPrefix: String = ""
    private var selectionSuffix: String = ""

    @Published var focusedAnnotation: UUID? = nil
    /// When the user creates an annotation via ⌘⇧N, the annotation appears
    /// with an empty note and the editor opens. Each transition of
    /// editingAnnotationID *away* from a value commits any pending
    /// annotation: the `created` event fires here, not at append time,
    /// so the watch loop sees the finished note instead of an empty
    /// shell. (Highlights via ⌘⇧H are complete on creation and emit
    /// immediately — they don't go through this path.)
    @Published var editingAnnotationID: UUID? = nil {
        didSet {
            if let prev = oldValue, prev != editingAnnotationID {
                commitPendingAnnotation(id: prev)
            }
        }
    }
    /// Set of annotation ids that were created via the note-editor path
    /// and haven't surfaced as `created` events yet. They commit when
    /// editing moves off them.
    private var pendingCommitAnnotations: Set<UUID> = []

    // Bumped to trigger a PDF export in the WKWebView coordinator.
    @Published var pdfExportRequestedAt: Date? = nil

    // FSEvents-based watcher on the active file. Replaced whenever the
    // active fileURL changes (open / tab activate / close).
    private var fileWatcher: FileWatcher?

    var hasSelection: Bool { !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var sidecarURL: URL? {
        guard let u = fileURL else { return nil }
        return u.deletingLastPathComponent()
            .appendingPathComponent(".\(u.lastPathComponent).mindle.json")
    }

    // MARK: - Open

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            .plainText
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        // Already open in this window? Switch to its tab without re-reading from disk.
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            activate(tabID: existing.id)
            return
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Re-root the file tree only when the new file is outside the current scope.
            // Clicking a file inside a subfolder of the current root must preserve rooting.
            let shouldRebuildTree: Bool
            if let root = fileTree?.url {
                shouldRebuildTree = !Self.isDescendant(url: url, of: root)
            } else {
                shouldRebuildTree = true
            }

            // Persist the outgoing tab's in-memory state into its snapshot so
            // we can rehydrate it without going back to disk if the user
            // returns to it.
            snapshotActiveTab()

            let newTab = DocumentTab(id: UUID(), fileURL: url, rawText: text, annotations: [], lastSyncedText: text)
            tabs.append(newTab)
            activeTabID = newTab.id

            closeSearch()
            focusedAnnotation = nil
            editingAnnotationID = nil
            updateSelection(text: "", prefix: "", suffix: "")

            self.fileURL = url
            self.rawText = text
            self.lastSyncedText = text
            self.annotations = []
            self.loadSidecar()

            // Capture the sidecar-loaded annotations into the tab snapshot.
            snapshotActiveTab()

            if shouldRebuildTree {
                refreshFileTree()
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            updateWatcher()
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Live reload

    /// Re-reads the active file from disk in response to a watcher event.
    /// Annotations stay in memory and re-anchor against the new text via
    /// the JS pipeline; sidecar is untouched (annotations live there
    /// regardless of source-text changes).
    private func reloadFromDisk() {
        guard let url = fileURL else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Skip the WKWebView round-trip if the bytes round-tripped the
            // same — touching mtime alone is enough to fire a watcher event.
            guard text != rawText else { return }
            rawText = text
            // Keep the active tab snapshot in sync so a later switch-out
            // doesn't snapshot stale text.
            snapshotActiveTab()
        } catch {
            // File may have been moved or deleted. Keep the in-memory
            // text; user can decide whether to close the tab.
            NSSound.beep()
        }
    }

    private func updateWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
        guard let url = fileURL else { return }
        fileWatcher = FileWatcher(url: url) { [weak self] in
            self?.reloadFromDisk()
        }
    }

    // MARK: - Tabs

    func activate(tabID: UUID) {
        guard activeTabID != tabID,
              let target = tabs.first(where: { $0.id == tabID }) else { return }
        snapshotActiveTab()
        activeTabID = tabID
        loadTabState(target)
    }

    func closeTab(id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let isActive = (activeTabID == id)

        // Make sure the snapshot we save reflects the latest in-memory state.
        if isActive {
            snapshotActiveTab()
        }
        saveSidecar(forTab: tabs[i])

        tabs.remove(at: i)

        guard isActive else { return }

        if i < tabs.count {
            let target = tabs[i]
            activeTabID = target.id
            loadTabState(target)
        } else if let last = tabs.last {
            activeTabID = last.id
            loadTabState(last)
        } else {
            // Last tab closed — back to empty state.
            activeTabID = nil
            fileURL = nil
            rawText = ""
            lastSyncedText = ""
            annotations = []
            closeSearch()
            focusedAnnotation = nil
            editingAnnotationID = nil
            updateSelection(text: "", prefix: "", suffix: "")
            updateWatcher()
        }
    }

    private func snapshotActiveTab() {
        guard let id = activeTabID,
              let i = tabs.firstIndex(where: { $0.id == id }),
              let url = fileURL else { return }
        tabs[i].fileURL = url
        tabs[i].rawText = rawText
        tabs[i].annotations = annotations
        tabs[i].lastSyncedText = lastSyncedText
    }

    private func loadTabState(_ tab: DocumentTab) {
        fileURL = tab.fileURL
        rawText = tab.rawText
        lastSyncedText = tab.lastSyncedText
        annotations = tab.annotations
        closeSearch()
        focusedAnnotation = nil
        editingAnnotationID = nil
        updateSelection(text: "", prefix: "", suffix: "")
        updateWatcher()
    }

    // MARK: - File browser

    static let browsableExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    func refreshFileTree() {
        guard let url = fileURL else { fileTree = nil; return }
        fileTree = Self.buildTree(at: url.deletingLastPathComponent())
    }

    private static func isDescendant(url: URL, of ancestor: URL) -> Bool {
        let aPath = ancestor.standardizedFileURL.path
        let uPath = url.standardizedFileURL.path
        let prefix = aPath.hasSuffix("/") ? aPath : aPath + "/"
        return uPath.hasPrefix(prefix)
    }

    private static func buildTree(at dir: URL) -> FileNode? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return FileNode(url: dir, name: dir.lastPathComponent, isDirectory: true, children: [])
        }

        var children: [FileNode] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if let sub = buildTree(at: entry), !(sub.children ?? []).isEmpty {
                    children.append(sub)
                }
            } else if browsableExtensions.contains(entry.pathExtension.lowercased()) {
                children.append(FileNode(url: entry, name: entry.lastPathComponent, isDirectory: false, children: nil))
            }
        }

        children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return FileNode(url: dir, name: dir.lastPathComponent, isDirectory: true, children: children)
    }

    func toggleTheme() {
        switch theme {
        case .light: theme = .sepia
        case .sepia: theme = .dark
        case .dark:  theme = .light
        }
        saveSidecar()
    }

    // MARK: - Selection bridge

    func updateSelection(text: String, prefix: String, suffix: String) {
        selectionText = text
        selectionPrefix = prefix
        selectionSuffix = suffix
    }

    // MARK: - Annotations

    func highlightSelection() {
        guard hasSelection else { NSSound.beep(); return }
        if let i = annotations.firstIndex(where: {
            $0.text == selectionText && $0.prefix == selectionPrefix && $0.suffix == selectionSuffix
        }) {
            let removed = annotations[i]
            annotations.remove(at: i)
            if let url = fileURL {
                AnnotationEventLog.shared.append(
                    kind: .deleted,
                    path: url.path,
                    annotationID: removed.id,
                    annotation: nil,
                    clientID: nil
                )
            }
        } else {
            let ann = Annotation(
                text: selectionText,
                prefix: selectionPrefix,
                suffix: selectionSuffix,
                note: ""
            )
            annotations.append(ann)
            if let url = fileURL {
                AnnotationEventLog.shared.append(
                    kind: .created,
                    path: url.path,
                    annotationID: ann.id,
                    annotation: ann,
                    clientID: nil
                )
            }
        }
        saveSidecar()
    }

    func addNoteToSelection() {
        guard hasSelection else { NSSound.beep(); return }
        showAnnotations = true
        if let existing = annotations.first(where: {
            $0.text == selectionText && $0.prefix == selectionPrefix && $0.suffix == selectionSuffix
        }) {
            editingAnnotationID = existing.id
            focusedAnnotation = existing.id
        } else {
            let ann = Annotation(
                text: selectionText,
                prefix: selectionPrefix,
                suffix: selectionSuffix,
                note: ""
            )
            annotations.append(ann)
            // Defer the `created` event until the user finishes typing
            // the note — see editingAnnotationID's didSet. Emitting now
            // would race with the typing: the watch loop would wake on
            // an empty note before the user got past their first word.
            pendingCommitAnnotations.insert(ann.id)
            editingAnnotationID = ann.id
            focusedAnnotation = ann.id
            saveSidecar()
        }
    }

    /// Fire the deferred `created` event for an annotation that was
    /// opened via the note-editor path, now that the user has finished
    /// editing it. Called automatically when editingAnnotationID moves
    /// off this annotation (Done click, Return commit, focusing a
    /// different annotation, window/tab change).
    private func commitPendingAnnotation(id: UUID) {
        guard pendingCommitAnnotations.remove(id) != nil else { return }
        guard let url = fileURL,
              let ann = annotations.first(where: { $0.id == id }) else { return }
        AnnotationEventLog.shared.append(
            kind: .created,
            path: url.path,
            annotationID: ann.id,
            annotation: ann,
            clientID: nil
        )
    }

    func updateNote(id: UUID, note: String) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].note = note
        saveSidecar()
    }

    func delete(id: UUID) {
        // If the annotation never surfaced a `created` event (still in
        // the note-editor pending state), drop it from the pending set
        // so commitPendingAnnotation can't fire on a later
        // editingAnnotationID transition.
        pendingCommitAnnotations.remove(id)
        guard let url = fileURL else {
            annotations.removeAll { $0.id == id }
            saveSidecar()
            return
        }
        let removed = annotations.first(where: { $0.id == id })
        annotations.removeAll { $0.id == id }
        if removed != nil {
            AnnotationEventLog.shared.append(
                kind: .deleted,
                path: url.path,
                annotationID: id,
                annotation: nil,
                clientID: nil
            )
        }
        saveSidecar()
    }

    /// MCP-side annotation lookup. Returns the annotations for whichever
    /// tab in this window has `fileURL.path == path`, or nil if no tab
    /// matches. Caller (AppDelegate) iterates every store to find a hit.
    func annotations(forPath path: String) -> [Annotation]? {
        if let active = activeTabID,
           let tab = tabs.first(where: { $0.id == active }),
           tab.fileURL.path == path {
            // Active tab — in-memory annotations are authoritative.
            return annotations
        }
        if let tab = tabs.first(where: { $0.fileURL.path == path }) {
            return tab.annotations
        }
        return nil
    }

    /// MCP-side: append a message to an existing annotation's thread.
    /// Returns true if a matching annotation was found in any tab and
    /// the message was appended.
    @discardableResult
    func appendThreadMessage(
        forPath path: String,
        annotationID: UUID,
        author: String,
        text: String,
        clientID: String? = nil
    ) -> Bool {
        let message = AnnotationMessage(author: author, text: text)
        if let active = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == active }),
           tabs[i].fileURL.path == path {
            guard let j = annotations.firstIndex(where: { $0.id == annotationID }) else {
                return false
            }
            var thread = annotations[j].thread ?? []
            thread.append(message)
            annotations[j].thread = thread
            saveSidecar()
            AnnotationEventLog.shared.append(
                kind: .threadReply,
                path: path,
                annotationID: annotationID,
                annotation: annotations[j],
                messageID: message.id,
                clientID: clientID
            )
            return true
        }
        if let i = tabs.firstIndex(where: { $0.fileURL.path == path }) {
            guard let j = tabs[i].annotations.firstIndex(where: { $0.id == annotationID }) else {
                return false
            }
            var thread = tabs[i].annotations[j].thread ?? []
            thread.append(message)
            tabs[i].annotations[j].thread = thread
            saveSidecar(forTab: tabs[i])
            AnnotationEventLog.shared.append(
                kind: .threadReply,
                path: path,
                annotationID: annotationID,
                annotation: tabs[i].annotations[j],
                messageID: message.id,
                clientID: clientID
            )
            return true
        }
        return false
    }

    /// MCP-side: create a new annotation authored by the agent. The
    /// agent supplies the anchor (text+prefix+suffix) and the note,
    /// just like a user creating one via ⌘⇧N. Returns the new
    /// annotation's id, or nil if the file isn't open in this store.
    func createAgentAnnotation(
        forPath path: String,
        text: String,
        prefix: String,
        suffix: String,
        note: String,
        clientID: String? = nil
    ) -> UUID? {
        let ann = Annotation(
            text: text,
            prefix: prefix,
            suffix: suffix,
            note: note,
            author: "agent",
            thread: nil
        )
        if let active = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == active }),
           tabs[i].fileURL.path == path {
            annotations.append(ann)
            showAnnotations = true
            saveSidecar()
            AnnotationEventLog.shared.append(
                kind: .created,
                path: path,
                annotationID: ann.id,
                annotation: ann,
                clientID: clientID
            )
            return ann.id
        }
        if let i = tabs.firstIndex(where: { $0.fileURL.path == path }) {
            tabs[i].annotations.append(ann)
            saveSidecar(forTab: tabs[i])
            AnnotationEventLog.shared.append(
                kind: .created,
                path: path,
                annotationID: ann.id,
                annotation: ann,
                clientID: clientID
            )
            return ann.id
        }
        return nil
    }

    /// MCP-side annotation clear. Removes the annotation with the given
    /// id from the matching tab and persists the sidecar. Returns true
    /// if a tab matched and the annotation was found+removed. The
    /// summary is stashed in NSLog for now — Phase 3 surfaces it in the
    /// UI as a chip next to the corresponding diff chunk.
    @discardableResult
    func removeAnnotation(forPath path: String, id: UUID, summary: String, clientID: String? = nil) -> Bool {
        NSLog("[mindle.mcp] clear_annotation path=%@ id=%@ summary=%@", path, id.uuidString, summary)
        if let active = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == active }),
           tabs[i].fileURL.path == path {
            guard annotations.contains(where: { $0.id == id }) else { return false }
            annotations.removeAll { $0.id == id }
            // saveSidecar() pulls from in-memory annotations of the
            // active tab, so this persists correctly.
            saveSidecar()
            AnnotationEventLog.shared.append(
                kind: .deleted,
                path: path,
                annotationID: id,
                annotation: nil,
                clientID: clientID
            )
            return true
        }
        if let i = tabs.firstIndex(where: { $0.fileURL.path == path }) {
            guard tabs[i].annotations.contains(where: { $0.id == id }) else { return false }
            tabs[i].annotations.removeAll { $0.id == id }
            saveSidecar(forTab: tabs[i])
            AnnotationEventLog.shared.append(
                kind: .deleted,
                path: path,
                annotationID: id,
                annotation: nil,
                clientID: clientID
            )
            return true
        }
        return false
    }

    func jumpTo(id: UUID) {
        focusedAnnotation = id
    }

    // MARK: - Diff review (v1.6)

    /// True while the on-disk text has diverged from the user's last
    /// reviewed baseline — i.e., an external edit landed and hasn't
    /// been accepted or rejected yet.
    var hasInFlightDiff: Bool { lastSyncedText != rawText }

    /// Accept all in-flight changes: the new text becomes the baseline.
    /// No file mutation — the disk already has the new text.
    func acceptAllChanges() {
        guard hasInFlightDiff else { return }
        lastSyncedText = rawText
        snapshotActiveTab()
        saveSidecar()
    }

    /// Reject all in-flight changes: write the baseline back to disk.
    /// The watcher will fire on the rewrite and reloadFromDisk no-ops
    /// (rawText already matches), so we're not racing with ourselves.
    func rejectAllChanges() {
        guard hasInFlightDiff, let url = fileURL else { return }
        let reverted = lastSyncedText
        rawText = reverted
        do {
            try reverted.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
        snapshotActiveTab()
        saveSidecar()
    }

    /// JS-side accept of a single chunk produces a new lastSyncedText
    /// that incorporates that chunk's "after" content. Swift just stores
    /// it; the WebView re-renders the now-smaller diff.
    func setLastSyncedText(_ text: String) {
        guard text != lastSyncedText else { return }
        lastSyncedText = text
        snapshotActiveTab()
        saveSidecar()
    }

    /// JS-side reject of a single chunk produces a new rawText that
    /// reverts that chunk to its "before" content. Swift writes through
    /// to disk; the watcher will reflect the rewrite without re-firing
    /// the diff render (rawText already matches).
    func setRawText(_ text: String) {
        guard text != rawText, let url = fileURL else { return }
        rawText = text
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
        snapshotActiveTab()
        saveSidecar()
    }

    // MARK: - PDF export

    var canExportPDF: Bool { fileURL != nil }

    func requestPDFExport() {
        guard canExportPDF else { NSSound.beep(); return }
        pdfExportRequestedAt = Date()
    }

    // MARK: - Search

    func toggleSearch() {
        if showSearch { closeSearch() } else { openSearch() }
    }

    func openSearch() {
        guard fileURL != nil else { NSSound.beep(); return }
        showSearch = true
    }

    func closeSearch() {
        showSearch = false
        searchQuery = ""
        searchTotal = 0
        searchCurrent = 0
    }

    func nextMatch() {
        guard showSearch, searchTotal > 0 else { return }
        searchNextRequestedAt = Date()
    }

    func previousMatch() {
        guard showSearch, searchTotal > 0 else { return }
        searchPrevRequestedAt = Date()
    }

    func updateSearchResult(total: Int, current: Int) {
        searchTotal = total
        searchCurrent = current
    }

    // MARK: - Persistence

    private struct Sidecar: Codable {
        var annotations: [Annotation]
        var theme: ReaderTheme?
        var fontScale: Double?
        /// Persisted only when the user has an unfinished diff review —
        /// i.e., `lastSyncedText != rawText`. On reopen, this restores the
        /// review state so a closed-and-relaunched window picks up where
        /// it left off. Nil when there's no in-flight diff (the common
        /// case), so existing v1.5 sidecars decode cleanly.
        var lastSyncedText: String?
    }

    private func loadSidecar() {
        guard let url = sidecarURL,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Sidecar.self, from: data) {
            annotations = decoded.annotations
            if let t = decoded.theme { theme = t }
            if let s = decoded.fontScale { fontScale = s }
            if let baseline = decoded.lastSyncedText {
                lastSyncedText = baseline
            }
        }
    }

    func saveSidecar() {
        guard let url = sidecarURL else { return }
        let baseline = (lastSyncedText != rawText) ? lastSyncedText : nil
        writeSidecar(to: url, annotations: annotations, lastSynced: baseline)
    }

    private func saveSidecar(forTab tab: DocumentTab) {
        let url = tab.fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(tab.fileURL.lastPathComponent).mindle.json")
        let baseline = (tab.lastSyncedText != tab.rawText) ? tab.lastSyncedText : nil
        writeSidecar(to: url, annotations: tab.annotations, lastSynced: baseline)
    }

    private func writeSidecar(to url: URL, annotations: [Annotation], lastSynced: String?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sidecar = Sidecar(
            annotations: annotations,
            theme: theme,
            fontScale: fontScale,
            lastSyncedText: lastSynced
        )
        if let data = try? encoder.encode(sidecar) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Export

    enum ExportFormat { case markdown, json }

    var canExportAnnotations: Bool {
        fileURL != nil && !annotations.isEmpty
    }

    func exportAnnotationsWithPanel() {
        guard canExportAnnotations, let source = fileURL else { NSSound.beep(); return }

        let base = source.deletingPathExtension().lastPathComponent
        let panel = NSSavePanel()
        panel.title = "Export Annotations"
        panel.nameFieldStringValue = "\(base).annotations.md"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .json
        ]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format: ExportFormat = (url.pathExtension.lowercased() == "json") ? .json : .markdown
        do {
            let data = try renderAnnotations(format: format, sourceURL: source)
            try data.write(to: url, options: .atomic)
        } catch {
            NSSound.beep()
        }
    }

    private func renderAnnotations(format: ExportFormat, sourceURL: URL) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(annotations)
        case .markdown:
            return Data(renderAnnotationsMarkdown(sourceURL: sourceURL).utf8)
        }
    }

    private func renderAnnotationsMarkdown(sourceURL: URL) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let stamp = df.string(from: Date())
        let noun = annotations.count == 1 ? "highlight" : "highlights"

        var out: [String] = []
        out.append("# Annotations — \(sourceURL.lastPathComponent)")
        out.append("")
        out.append("*Exported \(stamp) · \(annotations.count) \(noun)*")
        out.append("")
        out.append("---")
        out.append("")

        for ann in annotations {
            out.append(ann.note.isEmpty ? "### Highlight" : "### Note")
            out.append("")
            let quoted = ann.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            out.append(quoted)
            out.append("")
            if !ann.note.isEmpty {
                out.append(ann.note)
                out.append("")
            }
            out.append("---")
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
