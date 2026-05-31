import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

extension URL {
    /// Canonical filesystem path with symlinks fully resolved. The match
    /// key for any cross-process / MCP-style file lookup: `/tmp/foo`
    /// (a symlink) and `/private/tmp/foo` (the resolved path) both
    /// normalise to the same string. `standardizedFileURL` only resolves
    /// trailing-component symlinks, which is why MCP path matching used
    /// to fail for files under `/tmp` on macOS.
    var canonicalPath: String {
        resolvingSymlinksInPath().path
    }
}

enum ReaderTheme: String, CaseIterable, Codable {
    case light, sepia, dark
}

/// What kind of document is in the active tab — picks the renderer pipeline.
/// Markdown flows through the WKWebView + markdown-it pipeline; PDF flows
/// through the native PDFKit pipeline. Derived from the file URL's extension
/// rather than stored, so a tab's kind always matches its actual file.
/// Coarse PDF-load health. Surfaced in the reader pane as a banner so the
/// user understands why annotation isn't working when it isn't, instead
/// of staring at a silent blank page (locked) or a paper that won't
/// highlight (scanned without an OCR layer).
enum PDFTabStatus: Equatable {
    case ok
    case locked
    case noExtractableText
    case unloadable
}

/// One in-flight markdown block edit. Captured when the user invokes
/// the editor (⌘E) against a selection; the enclosing block becomes the
/// edit target. `originalText` is what was there at open time and is
/// used as the find-half of a find-and-replace when the user clicks
/// Save. `originalHash` is the same content's FNV-1a digest at open
/// time — re-hashed on Save to detect drift if the file changed
/// externally while editing.
struct EditingBlock: Equatable {
    let originalText: String
    let originalHash: String
}

enum DocumentKind: String {
    case markdown
    case pdf

    static func kind(for url: URL?) -> DocumentKind {
        guard let url else { return .markdown }
        return url.pathExtension.lowercased() == "pdf" ? .pdf : .markdown
    }
}

/// Three-stop content-column width. Narrow is the historical default and
/// the typography-recommended range (~90 chars/line at 18px serif);
/// Medium and Wide trade reading optimality for using more of the
/// horizontal space on large displays.
enum ReadingWidth: String, CaseIterable, Codable {
    case narrow, medium, wide
}

/// Reader font family. `.serif` is the historical New York / Iowan Old
/// Style stack; `.openDyslexic` swaps in the OpenDyslexic face (bundled
/// under SIL OFL in Resources/web/vendor/opendyslexic) for body and
/// headings — code blocks stay monospace either way.
///
/// Raw values are explicit lowercase: the rawValue is what we hand to JS,
/// which writes it into the `data-reading-font` attribute. CSS attribute
/// matching is case-sensitive by default, so an enum-default camelCase
/// rawValue ("openDyslexic") silently misses the `[data-reading-font=
/// "opendyslexic"]` selector and the font never swaps.
enum ReadingFont: String, CaseIterable, Codable {
    case serif = "serif"
    case openDyslexic = "opendyslexic"
}

/// A reaction (👍 / ❤️ / 😄) on an annotation or a thread message. One
/// (author, kind) pair per reactor per target — toggling re-applies or
/// removes that pair. `kind` is intentionally a String so older builds
/// decode unknown reaction kinds without erroring; renderers fall back
/// to a generic glyph for anything outside the known vocabulary.
struct AnnotationReaction: Codable, Equatable {
    var author: String        // collaborator alias
    var kind: String          // "+1" | "heart" | "laugh" (open-ended)
    var createdAt: Date = Date()
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
    /// Optional reactions on this message. Nil when none so older
    /// sidecars round-trip clean and the JSON stays compact.
    var reactions: [AnnotationReaction]?
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

    // Collab extensions (all optional for backward compat with existing sidecars)
    var status: AnnotationStatus?    // nil treated as .open
    var assignee: String?            // collaborator alias
    var labels: [String]?            // e.g. ["question", "blocker"]
    var resolvedBy: String?
    var resolvedAt: Date?
    /// Optional reactions on the annotation as a whole. Replies have
    /// their own reactions field on AnnotationMessage.
    var reactions: [AnnotationReaction]?

    // PDF-specific anchor extensions (nil on Markdown annotations).
    /// 0-based index of the PDF page this annotation is anchored on.
    /// Speeds re-anchor on reopen — search the stored page first and
    /// fall back to a broader cross-page scan only if it misses.
    var pageIndex: Int?
    /// FNV-1a hash of the full PDFPage.string at create time. Used to
    /// detect drift: if the same page hashes differently on reopen
    /// (extraction varied, document re-saved), the prefix/suffix
    /// anchor may have moved — UI can flag the annotation as
    /// "possibly orphaned" instead of silently misplacing the highlight.
    var pageTextHash: String?
}

enum AnnotationStatus: String, Codable {
    case open, resolved, wontfix
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
    /// Collaborator registry for this document. Snapshotted on tab
    /// switch-out and restored on switch-in so a window with multiple
    /// docs open shows each document's own author colors/aliases.
    var collaborators: [String: DocumentStore.SidecarCollaborator] = [:]
    /// Original URL for tabs whose `fileURL` is a local cache copy —
    /// today only set on URL-fetched PDFs, where `fileURL` points at
    /// `~/Library/Application Support/Mindle/url-pdfs/<hash>.pdf` and
    /// this carries the http(s) URL the user actually opened. Used for
    /// the tab title (`<hash>.pdf` is unreadable) and for the openURL
    /// dedup check (so re-opening the same URL re-activates the tab
    /// instead of fetching again).
    var sourceURL: URL? = nil
    /// True when an external file or sidecar change landed on this tab
    /// while another tab was active. The TabBar shows a small dot at the
    /// tab's leading edge until the user activates the tab, at which
    /// point the flag is cleared. Watchers for inactive tabs flip this;
    /// the active-tab watcher runs the existing reload paths instead.
    var hasUnread: Bool = false
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var fileURL: URL?
    @Published var rawText: String = ""
    @Published var annotations: [Annotation] = []
    /// Collaborator registry loaded from sidecar — maps alias to display info.
    @Published var collaborators: [String: SidecarCollaborator] = [:]
    /// Baseline for diff-on-reload. When `lastSyncedText != rawText`, the
    /// reader view shows track-changes between the two. Accepting clears
    /// the diff (lastSyncedText := rawText); rejecting reverts the
    /// document on disk (rawText := lastSyncedText, written through).
    @Published var lastSyncedText: String = ""

    @Published var theme: ReaderTheme = .sepia
    @Published var fontScale: Double = 1.0
    @Published var readingWidth: ReadingWidth = DocumentStore.persistedReadingWidth()
    @Published var readingFont: ReadingFont = DocumentStore.persistedReadingFont()
    @Published var bionicText: Bool = false
    /// Status of the active PDF tab (or `.ok` for any non-PDF tab).
    /// Set by `PDFReaderView` after `PDFDocument(url:)` resolves; reset
    /// to `.ok` whenever we transition to a Markdown tab so the banner
    /// doesn't leak across switches.
    @Published var pdfStatus: PDFTabStatus = .ok
    /// Annotation ids on the active PDF tab whose anchor didn't resolve
    /// against the current document — the card still lives in the
    /// sidebar but the page overlay isn't drawn. `AnnotationCard` reads
    /// this set to render a small "anchor drifted" cue. Markdown tabs
    /// leave it empty (their anchor resolution lives in the JS pipeline
    /// at render time, not surfaced here).
    @Published var orphanedAnnotations: Set<UUID> = []

    /// UserDefaults keys for the user-level (cross-document) default of
    /// each reader preference. Sidecar still wins per-doc if it carries
    /// an explicit value (back-compat with v2.2.0 sidecars); these are
    /// the fallback for any new doc opened without an override.
    private static let defaultsKeyReadingWidth = "mindle.readingWidth"
    private static let defaultsKeyReadingFont = "mindle.readingFont"

    private static func persistedReadingWidth() -> ReadingWidth {
        if let raw = UserDefaults.standard.string(forKey: defaultsKeyReadingWidth),
           let w = ReadingWidth(rawValue: raw) { return w }
        return .narrow
    }

    private static func persistedReadingFont() -> ReadingFont {
        if let raw = UserDefaults.standard.string(forKey: defaultsKeyReadingFont),
           let f = ReadingFont(rawValue: raw) { return f }
        return .serif
    }

    /// Menu-action setter. Updates the visible state *and* persists the
    /// choice as the new user-level default, so the next file opened
    /// (without an explicit sidecar override) starts at this value.
    /// Avoid mutating `readingWidth` directly from menus — that path
    /// skips the UserDefaults write and the persistence falls apart.
    func setReadingWidth(_ width: ReadingWidth) {
        readingWidth = width
        UserDefaults.standard.set(width.rawValue, forKey: Self.defaultsKeyReadingWidth)
    }

    func setReadingFont(_ font: ReadingFont) {
        readingFont = font
        UserDefaults.standard.set(font.rawValue, forKey: Self.defaultsKeyReadingFont)
    }

    /// Reset width/font to the user-level UserDefaults default. Call this
    /// before `loadSidecar()` on every "open a new file" path so the
    /// previous document's per-doc sidecar override doesn't leak into a
    /// fresh tab that has no override of its own. Sidecar-watcher reloads
    /// must NOT call this — the user may have manually picked a width on
    /// the open doc that we'd then erase on every external sidecar bump.
    private func resetReaderPrefsToUserDefaults() {
        readingWidth = Self.persistedReadingWidth()
        readingFont = Self.persistedReadingFont()
    }
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
    /// PDF anchor metadata for the most recent applyHighlight/applyNote
    /// call. Nil for Markdown captures; populated when PDFReaderView
    /// hands off a PDF selection. Consumed (and cleared) by the next
    /// `highlightSelection` / `addNoteToSelection` invocation so it
    /// can't leak into a subsequent Markdown selection on the same
    /// window.
    private var pendingPageIndex: Int?
    private var pendingPageTextHash: String?

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

    // ⌘⇧H / ⌘⇧N can't use the cached selection — it's debounced 150ms in
    // JS, so a quick select-then-hotkey would read stale or empty state.
    // These signals tell WebReaderView to probe the live selection via
    // window.mindleCaptureSelectionNow(), then call back into
    // applyHighlight / applyNote with the fresh values.
    @Published var highlightRequestedAt: Date? = nil
    @Published var noteRequestedAt: Date? = nil
    /// Bumped by the View → Fit Width menu action (⌘0). PDFReaderView
    /// observes this to reset its scale factor to fit-width after the
    /// user has manually zoomed. No-op on Markdown tabs.
    @Published var pdfFitWidthRequestedAt: Date? = nil
    /// The whole-document edit session in progress, or nil when the
    /// editor is closed. Setting non-nil opens the EditingPane; nil
    /// closes it. Holds the rawText + hash at open time so stage 4's
    /// drift detection has a baseline. v3.1 ships whole-doc only —
    /// block-scoped editing was the original sketch but the user's
    /// brief is "the bare text," so we open the full file source.
    @Published var editingBlock: EditingBlock? = nil

    // FSEvents-based watcher on the active file. Replaced whenever the
    // active fileURL changes (open / tab activate / close).
    private var fileWatcher: FileWatcher?
    // Sibling watcher on the active file's sidecar. Picks up external
    // annotation edits — another Mindle instance writing through a
    // shared folder, a git pull, a teammate's collab tool — and reloads
    // them into the active tab.
    private var sidecarWatcher: FileWatcher?
    /// Timestamp of the most recent in-process `writeSidecar`. Used to
    /// suppress the FSEvents echo that our own atomic write triggers.
    private var lastSelfSidecarWriteAt: Date?

    /// Watchers covering every tab that is *not* the active one. Their
    /// only job is to set `DocumentTab.hasUnread = true` so the TabBar
    /// can render a dot. The active tab is intentionally absent here —
    /// `fileWatcher` / `sidecarWatcher` already handle its reloads, and
    /// duplicating watchers would cause every active reload to bump the
    /// (unrelated) unread flag.
    private var inactiveFileWatchers: [UUID: FileWatcher] = [:]
    private var inactiveSidecarWatchers: [UUID: FileWatcher] = [:]

    var hasSelection: Bool { !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Current document's renderer kind, derived from the active file URL.
    /// `ReaderPane` reads this to pick between WKWebView (markdown) and
    /// PDFView (pdf). Remote URL and clipboard tabs are always markdown.
    var documentKind: DocumentKind { DocumentKind.kind(for: fileURL) }

    private var sidecarURL: URL? {
        guard let u = fileURL else { return nil }
        return Self.sidecarURL(for: u)
    }

    /// Sidecar URL for an arbitrary document URL — same logic as the
    /// instance property, but addressable for any tab (needed by the
    /// per-tab inactive watchers). Same three branches: http(s) sidecars
    /// in app support keyed by a stable hash; clipboard:// sidecars
    /// content-addressed by the URL's last path component; everything
    /// else writes a dot-prefixed adjacent file.
    static func sidecarURL(for u: URL) -> URL? {
        if u.scheme == "http" || u.scheme == "https" {
            return urlSidecarsDir()?
                .appendingPathComponent("\(urlKey(for: u)).mindle.json")
        }
        if u.scheme == "clipboard" {
            let hash = u.lastPathComponent
            return clipboardSidecarsDir()?
                .appendingPathComponent("\(hash).mindle.json")
        }
        return u.deletingLastPathComponent()
            .appendingPathComponent(".\(u.lastPathComponent).mindle.json")
    }

    /// ~/Library/Application Support/Mindle/url-sidecars/. Created on first
    /// access. Used to persist annotations for remote URL documents.
    private static func urlSidecarsDir() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = support
            .appendingPathComponent("Mindle", isDirectory: true)
            .appendingPathComponent("url-sidecars", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    /// ~/Library/Application Support/Mindle/clipboard-sidecars/. Sibling of
    /// `urlSidecarsDir`. Sidecar filename is the content hash, so identical
    /// pastes round-trip to the same annotations.
    private static func clipboardSidecarsDir() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = support
            .appendingPathComponent("Mindle", isDirectory: true)
            .appendingPathComponent("clipboard-sidecars", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    /// FNV-1a 64-bit hash of an arbitrary UTF-8 string. Used for content
    /// hashing of pasted clipboard text and PDF page-text fingerprints —
    /// stable across launches, fits in a filename, collision-resistant
    /// for human-scale paste / page volumes.
    static func contentHash(_ text: String) -> String {
        var h: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        return String(format: "%016llx", h)
    }

    /// FNV-1a 64-bit hash of the URL's absolute string. Stable across launches,
    /// short enough for a filename, collision-resistant for human-scale URL counts.
    private static func urlKey(for url: URL) -> String {
        var h: UInt64 = 14695981039346656037
        for byte in url.absoluteString.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        return String(format: "%016llx", h)
    }

    // MARK: - Open

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
            .plainText,
            .pdf
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
            // PDFs don't go through the UTF-8 text path — PDFReaderView
            // renders directly from the file URL. rawText stays empty so
            // the markdown pipeline (markdown-it, search, highlight, diff)
            // doesn't try to do anything with the binary PDF bytes.
            let kind = DocumentKind.kind(for: url)
            let text: String = (kind == .pdf)
                ? ""
                : try String(contentsOf: url, encoding: .utf8)
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
            self.collaborators = [:]
            self.resetReaderPrefsToUserDefaults()
            self.loadSidecar()

            // Capture the sidecar-loaded annotations into the tab snapshot.
            snapshotActiveTab()

            if shouldRebuildTree {
                refreshFileTree()
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            updateWatcher()
            // The previously-active tab is now inactive — give it a
            // watcher pair so external changes can flip its unread flag.
            syncInactiveWatchers()
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
        sidecarWatcher?.stop()
        sidecarWatcher = nil
        guard let url = fileURL else { return }
        // FSEvents only meaningfully watches local files. Remote URL tabs
        // don't get a watcher — refreshing means re-opening from the menu.
        guard url.isFileURL else { return }
        // Body watcher is for live-reload of Markdown source via
        // `String(contentsOf:)`. On a PDF tab those bytes aren't UTF-8;
        // the read fails and `reloadFromDisk` beeps every time PDFKit
        // touches the file. PDF tabs render directly from the URL via
        // PDFView, so they need no body watcher at all. Sidecar watcher
        // still applies — that's how teammates' annotation edits flow
        // in.
        if DocumentKind.kind(for: url) != .pdf {
            fileWatcher = FileWatcher(url: url) { [weak self] in
                self?.reloadFromDisk()
            }
        }
        if let sidecar = sidecarURL, sidecar.isFileURL {
            sidecarWatcher = FileWatcher(url: sidecar) { [weak self] in
                self?.reloadSidecarFromDisk()
            }
        }
    }

    /// Maintains `inactiveFileWatchers` / `inactiveSidecarWatchers`. Called
    /// after any tab-set change (open, activate, close) so the watcher set
    /// always matches "every tab except the active one." A watcher fire on
    /// an inactive tab flips `hasUnread`; the TabBar renders a dot until
    /// the user activates the tab.
    private func syncInactiveWatchers() {
        let activeID = activeTabID
        let inactiveIDs = Set(tabs.filter { $0.id != activeID }.map { $0.id })

        // Stop watchers for tabs that are no longer inactive (became active
        // or were closed).
        for id in Array(inactiveFileWatchers.keys) where !inactiveIDs.contains(id) {
            inactiveFileWatchers[id]?.stop()
            inactiveFileWatchers.removeValue(forKey: id)
        }
        for id in Array(inactiveSidecarWatchers.keys) where !inactiveIDs.contains(id) {
            inactiveSidecarWatchers[id]?.stop()
            inactiveSidecarWatchers.removeValue(forKey: id)
        }

        // Start watchers for inactive tabs that don't have one yet.
        for tab in tabs where tab.id != activeID {
            let url = tab.fileURL
            guard url.isFileURL else { continue }
            let id = tab.id
            if inactiveFileWatchers[id] == nil,
               DocumentKind.kind(for: url) != .pdf {
                inactiveFileWatchers[id] = FileWatcher(url: url) { [weak self] in
                    self?.markTabUnread(id)
                }
            }
            if inactiveSidecarWatchers[id] == nil,
               let sidecar = Self.sidecarURL(for: url),
               sidecar.isFileURL {
                inactiveSidecarWatchers[id] = FileWatcher(url: sidecar) { [weak self] in
                    self?.markTabUnread(id)
                }
            }
        }
    }

    /// Flip the unread flag on a non-active tab. No-op if the tab has
    /// already been marked or no longer exists.
    private func markTabUnread(_ tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if !tabs[i].hasUnread {
            tabs[i].hasUnread = true
        }
    }

    /// Sidecar-watcher callback. Suppresses the echo from our own
    /// `writeSidecar` (FSEvents fires on every atomic save) by ignoring
    /// events that arrive within 750ms of the last self-write; anything
    /// past that is a genuine external change and gets pulled in via
    /// `loadSidecar()`. Active-tab snapshot stays consistent with the
    /// reloaded state.
    private func reloadSidecarFromDisk() {
        if let last = lastSelfSidecarWriteAt,
           Date().timeIntervalSince(last) < 0.75 {
            return
        }
        DebugConsole.shared.log("SIDECAR: external change, reloading")
        loadSidecar()
        snapshotActiveTab()
    }

    // MARK: - Open URL

    /// Prompt the user for an http(s) URL and open it as a remote-content
    /// tab. The fetched markdown opens like any other document — search,
    /// annotations, export all work the same. Annotations persist to a
    /// per-URL sidecar in app support (see `sidecarURL`).
    func openURLWithPrompt() {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Enter the URL of a Markdown document (raw .md)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com/README.md"
        // Auto-fill from clipboard when it looks like a URL — saves a paste.
        if let pb = NSPasteboard.general.string(forType: .string),
           let u = URL(string: pb.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = u.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            field.stringValue = pb.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Be friendly to "arxiv.org/pdf/2407.00143"-style input — prepend
        // https:// when no scheme is present. The validation below still
        // rejects anything weird (ftp://, file://, garbage) so this only
        // helps the common "I forgot the prefix" case.
        let candidate = raw.contains("://") ? raw : (raw.isEmpty ? raw : "https://" + raw)
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            let invalid = NSAlert()
            invalid.messageText = "That doesn't look like an http(s) URL."
            invalid.runModal()
            return
        }
        openURL(url)
    }

    /// Open an http(s) URL: fetch the body off-main and open it as a tab
    /// keyed on the URL. Already-open URLs activate instead of refetching.
    func openURL(_ url: URL) {
        // Check both fileURL (markdown URLs whose tab keeps the http URL)
        // and sourceURL (PDFs whose fileURL was swapped to a cache path
        // by handleURLResponse but whose sourceURL preserves the original).
        // Without the sourceURL check, re-opening the same PDF URL after
        // it cached would create a duplicate tab.
        if let existing = tabs.first(where: { $0.fileURL == url || $0.sourceURL == url }) {
            activate(tabID: existing.id)
            return
        }

        // Open a placeholder tab immediately so the user sees the request
        // landed; the fetch fills in the content when it returns.
        snapshotActiveTab()
        let placeholder = "# Loading…\n\n`\(url.absoluteString)`\n"
        let newTab = DocumentTab(
            id: UUID(),
            fileURL: url,
            rawText: placeholder,
            annotations: [],
            lastSyncedText: placeholder
        )
        tabs.append(newTab)
        let newTabID = newTab.id
        activeTabID = newTabID
        fileURL = url
        rawText = placeholder
        lastSyncedText = placeholder
        annotations = []
        collaborators = [:]
        closeSearch()
        focusedAnnotation = nil
        editingAnnotationID = nil
        updateSelection(text: "", prefix: "", suffix: "")
        updateWatcher()  // no-op for remote URLs; clears any prior watcher
        syncInactiveWatchers()

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handleURLResponse(
                    tabID: newTabID, url: url,
                    data: data, response: response, error: error
                )
            }
        }
        task.resume()
    }

    // MARK: - Open from Clipboard

    /// Open the current pasteboard contents as a Markdown document.
    /// Tab identity is a content-addressed pseudo-URL
    /// `clipboard:///<contentHash>` so re-pasting identical text re-opens
    /// the same tab and re-attaches to the prior annotations. Sidesteps
    /// auth entirely — Chrome (or wherever the user copied from) owns the
    /// session; Mindle just carries the rendered bytes across.
    func openFromClipboard() {
        let pb = NSPasteboard.general
        guard let raw = pb.string(forType: .string) else {
            NSSound.beep()
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return
        }
        let hash = Self.contentHash(raw)
        guard let url = URL(string: "clipboard:///\(hash)") else {
            NSSound.beep()
            return
        }
        // Same identical text already open in this window? Activate it
        // instead of stacking a duplicate tab.
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            activate(tabID: existing.id)
            return
        }
        snapshotActiveTab()
        let newTab = DocumentTab(
            id: UUID(),
            fileURL: url,
            rawText: raw,
            annotations: [],
            lastSyncedText: raw
        )
        tabs.append(newTab)
        activeTabID = newTab.id
        fileURL = url
        rawText = raw
        lastSyncedText = raw
        annotations = []
        collaborators = [:]
        closeSearch()
        focusedAnnotation = nil
        editingAnnotationID = nil
        updateSelection(text: "", prefix: "", suffix: "")
        // No body watcher (no file to watch); sidecar watcher is wired up
        // inside updateWatcher when the sidecar URL resolves to a file.
        updateWatcher()
        syncInactiveWatchers()
        resetReaderPrefsToUserDefaults()
        loadSidecar()
        snapshotActiveTab()
    }

    @MainActor
    private func handleURLResponse(
        tabID: UUID, url: URL,
        data: Data?, response: URLResponse?, error: Error?
    ) {
        // If the user closed the tab while the request was in flight, drop
        // the result on the floor — the URL is no longer being viewed.
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        if let error {
            applyTextBody(
                tabIdx: idx, tabID: tabID,
                body: "# Couldn't load\n\n`\(url.absoluteString)`\n\n```\n\(error.localizedDescription)\n```\n"
            )
            return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            applyTextBody(
                tabIdx: idx, tabID: tabID,
                body: "# HTTP \(http.statusCode)\n\n`\(url.absoluteString)`\n"
            )
            return
        }
        guard let data else {
            applyTextBody(
                tabIdx: idx, tabID: tabID,
                body: "# Couldn't load\n\n`\(url.absoluteString)`\n"
            )
            return
        }

        // PDF response → swap the tab over to the PDFKit pipeline. We
        // cache the bytes to disk because PDFView needs a URL, not raw
        // data; this also gives future sessions something to point at
        // once URL-PDF sidecar persistence lands in stage 3.
        let looksLikePDF =
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().hasPrefix("application/pdf") == true
            || url.pathExtension.lowercased() == "pdf"
            || data.starts(with: [0x25, 0x50, 0x44, 0x46])   // "%PDF"
        if looksLikePDF {
            if let cacheURL = Self.cacheURLForRemotePDF(originalURL: url, data: data) {
                tabs[idx].fileURL = cacheURL
                tabs[idx].sourceURL = url
                tabs[idx].rawText = ""
                tabs[idx].lastSyncedText = ""
                if activeTabID == tabID {
                    fileURL = cacheURL
                    rawText = ""
                    lastSyncedText = ""
                    resetReaderPrefsToUserDefaults()
                    loadSidecar()
                    snapshotActiveTab()
                }
                return
            }
            // Cache write failed; fall through to the error message path.
            applyTextBody(
                tabIdx: idx, tabID: tabID,
                body: "# Couldn't cache PDF locally\n\n`\(url.absoluteString)`\n"
            )
            return
        }

        if let text = String(data: data, encoding: .utf8) {
            applyTextBody(tabIdx: idx, tabID: tabID, body: text)
        } else {
            applyTextBody(
                tabIdx: idx, tabID: tabID,
                body: "# Couldn't decode as UTF-8\n\n`\(url.absoluteString)`\n"
            )
        }
    }

    /// Common tail of `handleURLResponse` for text-bodied responses
    /// (markdown, plain text, error placeholders). Updates the tab's
    /// rawText and — if this is the active tab — mirrors into the
    /// window-scoped @Published vars + reloads the sidecar.
    @MainActor
    private func applyTextBody(tabIdx idx: Int, tabID: UUID, body: String) {
        tabs[idx].rawText = body
        tabs[idx].lastSyncedText = body
        if activeTabID == tabID {
            rawText = body
            lastSyncedText = body
            resetReaderPrefsToUserDefaults()
            loadSidecar()
            snapshotActiveTab()
        }
    }

    /// Write a fetched PDF to `~/Library/Application Support/Mindle/url-pdfs/<urlhash>.pdf`
    /// and return that URL so the tab can hand it to PDFView. The hash key
    /// is stable across launches (same as the url-sidecars key), so the
    /// same source URL re-fetches into the same cache file — handy when
    /// URL-PDF sidecar persistence lands in stage 3. Skips the write if
    /// the cache file already exists and the bytes match in length (a
    /// proxy for "same content"; full equality would re-read the cache
    /// off disk for nothing).
    private static func cacheURLForRemotePDF(originalURL: URL, data: Data) -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = support
            .appendingPathComponent("Mindle", isDirectory: true)
            .appendingPathComponent("url-pdfs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("\(Self.urlKey(for: originalURL)).pdf")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let size = attrs[.size] as? Int,
           size == data.count {
            return cacheURL
        }
        do {
            try data.write(to: cacheURL, options: .atomic)
            return cacheURL
        } catch {
            return nil
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

        // The removed tab may have had an inactive watcher pair; drop it.
        guard isActive else {
            syncInactiveWatchers()
            return
        }

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
            syncInactiveWatchers()
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
        tabs[i].collaborators = collaborators
    }

    private func loadTabState(_ tab: DocumentTab) {
        fileURL = tab.fileURL
        rawText = tab.rawText
        lastSyncedText = tab.lastSyncedText
        annotations = tab.annotations
        collaborators = tab.collaborators
        // Reset PDF status — PDFReaderView re-publishes the right value
        // for PDF tabs once the document re-loads; Markdown tabs stay
        // at .ok so the banner doesn't leak from a previously active
        // PDF tab.
        pdfStatus = .ok
        // Same lifecycle for orphan set — re-populated by
        // syncHighlightOverlays on PDF tabs; Markdown tabs stay empty.
        orphanedAnnotations = []
        closeSearch()
        focusedAnnotation = nil
        editingAnnotationID = nil
        updateSelection(text: "", prefix: "", suffix: "")
        // The tab is now visible — clear its unread dot. Keep the prior
        // value so we know to refresh from disk a few lines down.
        let hadUnread: Bool
        if let i = tabs.firstIndex(where: { $0.id == tab.id }) {
            hadUnread = tabs[i].hasUnread
            if tabs[i].hasUnread {
                tabs[i].hasUnread = false
            }
        } else {
            hadUnread = false
        }
        updateWatcher()
        syncInactiveWatchers()
        // If an inactive watcher flipped `hasUnread`, the snapshot we just
        // restored is stale — the external change landed after the tab
        // was snapshotted. Re-run the active-tab reload paths now so the
        // user sees the actual file content and the diff overlay can
        // surface the change. PDFs skip the body reload (PDFView watches
        // its URL directly), but every kind re-reads the sidecar in case
        // annotation traffic was the trigger.
        if hadUnread {
            if DocumentKind.kind(for: tab.fileURL) != .pdf {
                reloadFromDisk()
            }
            loadSidecar()
            snapshotActiveTab()
        }
    }

    // MARK: - File browser

    static let browsableExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "pdf"]

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

    /// Bump the request signal — WebReaderView observes this, fetches the
    /// live selection from JS, and calls applyHighlight with fresh values.
    func requestHighlight() {
        DebugConsole.shared.log("HIGHLIGHT requested")
        highlightRequestedAt = Date()
    }
    func requestNote() {
        DebugConsole.shared.log("NOTE requested")
        noteRequestedAt = Date()
    }

    /// Open the whole-document editor. No selection required; the
    /// editor pre-fills with the full rawText. Restricted to local-file
    /// markdown tabs — URL-fetched and clipboard tabs don't have a
    /// writable destination for Save. PDFs are out of v3.1 scope.
    func requestEdit() {
        DebugConsole.shared.log("EDIT requested")
        guard documentKind == .markdown,
              fileURL?.isFileURL == true else {
            NSSound.beep()
            return
        }
        editingBlock = EditingBlock(
            originalText: rawText,
            originalHash: Self.contentHash(rawText)
        )
    }

    /// Save the editor's draft back to disk and close the editor.
    ///
    /// First runs a drift check: if `rawText`'s current hash differs
    /// from the hash captured at edit-open time, an external writer
    /// (the file watcher pulled in a concurrent write from an agent /
    /// teammate / another app) has landed bytes under our feet. Show
    /// the user a three-way dialog: overwrite with their version,
    /// discard their edits, or stay in the editor to merge manually.
    /// Without this check, Save would silently clobber the external
    /// change.
    ///
    /// On the happy path: write the draft to fileURL atomically, update
    /// rawText + lastSyncedText (the latter becomes the new diff-on-
    /// reload baseline), snapshot the tab, close the editor. The file
    /// watcher's reloadFromDisk fires shortly after — finds text ==
    /// rawText and short-circuits, no echo loop.
    func commitEdit(draft: String) {
        guard let url = fileURL, url.isFileURL,
              let block = editingBlock else {
            NSSound.beep()
            return
        }
        DebugConsole.shared.log("EDIT save: \(draft.count) chars")

        let currentHash = Self.contentHash(rawText)
        if currentHash != block.originalHash {
            let action = promptDriftResolution()
            switch action {
            case .keepMine:
                break
            case .discardMine:
                editingBlock = nil
                return
            case .stayInEditor:
                return
            }
        }

        do {
            try draft.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DebugConsole.shared.log("EDIT save failed: \(error)")
            NSSound.beep()
            return
        }
        rawText = draft
        lastSyncedText = draft
        snapshotActiveTab()
        editingBlock = nil
    }

    private enum DriftResolution {
        case keepMine, discardMine, stayInEditor
    }

    private func promptDriftResolution() -> DriftResolution {
        let alert = NSAlert()
        alert.messageText = "This file changed while you were editing"
        alert.informativeText = "Another writer (an agent, another app, or a git pull) modified the file after you opened the editor. What would you like to do?"
        alert.addButton(withTitle: "Save My Version")
        alert.addButton(withTitle: "Discard My Edits")
        alert.addButton(withTitle: "Keep Editing")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  return .keepMine
        case .alertSecondButtonReturn: return .discardMine
        default:                       return .stayInEditor
        }
    }

    /// Called by WebReaderView once the JS round-trip returns the live
    /// selection. Overwrites the cached selection with the fresh capture,
    /// then runs the standard highlight/note path.
    func applyHighlight(
        text: String,
        prefix: String,
        suffix: String,
        pageIndex: Int? = nil,
        pageTextHash: String? = nil
    ) {
        DebugConsole.shared.log("HIGHLIGHT: '\(text.prefix(30))'")
        selectionText = text
        selectionPrefix = prefix
        selectionSuffix = suffix
        pendingPageIndex = pageIndex
        pendingPageTextHash = pageTextHash
        highlightSelection()
    }

    func applyNote(
        text: String,
        prefix: String,
        suffix: String,
        pageIndex: Int? = nil,
        pageTextHash: String? = nil
    ) {
        DebugConsole.shared.log("NOTE: '\(text.prefix(30))'")
        selectionText = text
        selectionPrefix = prefix
        selectionSuffix = suffix
        pendingPageIndex = pageIndex
        pendingPageTextHash = pageTextHash
        addNoteToSelection()
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
            var ann = Annotation(
                text: selectionText,
                prefix: selectionPrefix,
                suffix: selectionSuffix,
                note: "",
                author: IdentityManager.shared.alias
            )
            ann.pageIndex = pendingPageIndex
            ann.pageTextHash = pendingPageTextHash
            pendingPageIndex = nil
            pendingPageTextHash = nil
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
            var ann = Annotation(
                text: selectionText,
                prefix: selectionPrefix,
                suffix: selectionSuffix,
                note: "",
                author: IdentityManager.shared.alias
            )
            ann.pageIndex = pendingPageIndex
            ann.pageTextHash = pendingPageTextHash
            pendingPageIndex = nil
            pendingPageTextHash = nil
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
    /// tab in this window has a canonical-path match against `path`, or
    /// nil if no tab matches. Caller (AppDelegate) iterates every store
    /// to find a hit. Path matching canonicalises symlinks on both sides
    /// so e.g. `/tmp/foo` and `/private/tmp/foo` resolve to the same key.
    func annotations(forPath path: String) -> [Annotation]? {
        let canonical = URL(fileURLWithPath: path).canonicalPath
        if let active = activeTabID,
           let tab = tabs.first(where: { $0.id == active }),
           tab.fileURL.canonicalPath == canonical {
            // Active tab — in-memory annotations are authoritative.
            return annotations
        }
        if let tab = tabs.first(where: { $0.fileURL.canonicalPath == canonical }) {
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
        DebugConsole.shared.log("REPLY: to \(annotationID.uuidString.prefix(8)) by \(author)")
        let message = AnnotationMessage(author: author, text: text)
        let canonical = URL(fileURLWithPath: path).canonicalPath
        if let active = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == active }),
           tabs[i].fileURL.canonicalPath == canonical {
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
        if let i = tabs.firstIndex(where: { $0.fileURL.canonicalPath == canonical }) {
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
        var ann = Annotation(
            text: text,
            prefix: prefix,
            suffix: suffix,
            note: note,
            author: "agent",
            thread: nil
        )
        let canonical = URL(fileURLWithPath: path).canonicalPath
        if let active = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == active }),
           tabs[i].fileURL.canonicalPath == canonical {
            applyPDFAnchorIfApplicable(to: &ann, tabFileURL: tabs[i].fileURL)
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
        if let i = tabs.firstIndex(where: { $0.fileURL.canonicalPath == canonical }) {
            applyPDFAnchorIfApplicable(to: &ann, tabFileURL: tabs[i].fileURL)
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

    /// Mutates an agent-authored annotation in-place to stamp `pageIndex`
    /// and `pageTextHash` when the host tab is a PDF and the anchor text
    /// resolves on one of its pages. Markdown tabs no-op — there's no
    /// page concept; the JS pipeline finds anchors at render time. PDFs
    /// need the page index baked in at creation so the overlay
    /// pipeline knows where to draw.
    ///
    /// Resolution uses the same two-pass match (literal → flex-whitespace)
    /// that re-anchor on reopen uses, sharing the
    /// `PDFReaderView.findAnchorRange` helper. First page that matches
    /// wins — when the same text appears on multiple pages, the agent
    /// can constrain by supplying a more specific anchor. Prefix/suffix
    /// disambiguation now scores candidates by neighborhood overlap and
    /// picks the best across pages.
    private func applyPDFAnchorIfApplicable(to ann: inout Annotation, tabFileURL: URL) {
        guard DocumentKind.kind(for: tabFileURL) == .pdf,
              let resolved = resolvePDFAnchor(
                text: ann.text,
                prefix: ann.prefix,
                suffix: ann.suffix,
                fileURL: tabFileURL
              ) else {
            return
        }
        ann.pageIndex = resolved.pageIndex
        ann.pageTextHash = resolved.pageTextHash
    }

    /// Open the PDF at `fileURL`, score every page that contains the
    /// anchor text, and return the highest-scoring page. Score weights
    /// each candidate by how much of prefix + suffix matches the actual
    /// neighborhood — when the same text appears on multiple pages
    /// (figure caption referenced in body etc.), this picks the page
    /// where the surrounding chars actually correspond to the agent's
    /// view of the world. Falls back gracefully: a single match scores
    /// 0 and still wins; no matches anywhere returns nil and the agent's
    /// annotation lands without a page anchor.
    private func resolvePDFAnchor(
        text: String,
        prefix: String,
        suffix: String,
        fileURL: URL
    ) -> (pageIndex: Int, pageTextHash: String)? {
        guard let doc = PDFDocument(url: fileURL) else { return nil }
        let probe = Annotation(text: text, prefix: prefix, suffix: suffix, note: "")
        var best: (pageIndex: Int, pageTextHash: String, score: Int)?
        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx),
                  let pageText = page.string,
                  let candidate = PDFReaderView.bestAnchor(for: probe, in: pageText) else {
                continue
            }
            let hash = Self.contentHash(pageText)
            if best == nil || candidate.score > best!.score {
                best = (pageIdx, hash, candidate.score)
            }
        }
        guard let best else { return nil }
        return (best.pageIndex, best.pageTextHash)
    }

    /// MCP-side annotation clear. Removes the annotation with the given
    /// id from the matching tab and persists the sidecar. Returns true
    /// if a tab matched and the annotation was found+removed. The
    /// summary is stashed in NSLog for now — Phase 3 surfaces it in the
    /// UI as a chip next to the corresponding diff chunk.
    @discardableResult
    func removeAnnotation(forPath path: String, id: UUID, summary: String, clientID: String? = nil) -> Bool {
        NSLog("[mindle.mcp] clear_annotation path=%@ id=%@ summary=%@", path, id.uuidString, summary)
        let canonical = URL(fileURLWithPath: path).canonicalPath
        if let active = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == active }),
           tabs[i].fileURL.canonicalPath == canonical {
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
        if let i = tabs.firstIndex(where: { $0.fileURL.canonicalPath == canonical }) {
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
        /// Collaborator registry — maps alias to display info. Optional
        /// so existing sidecars without collab decode cleanly.
        var collaborators: [String: SidecarCollaborator]?
        /// Per-doc reading-width preference. Optional so older sidecars
        /// decode cleanly; missing = narrow (the v2.1 default).
        var readingWidth: ReadingWidth?
        /// Per-doc font preference. Optional; missing = serif default.
        var readingFont: ReadingFont?
        /// Bionic-text toggle. Optional/false default.
        var bionicText: Bool?
    }

    struct SidecarCollaborator: Codable, Equatable {
        var displayName: String
        var color: String
        var type: String?  // "human" or "agent"
    }

    private func loadSidecar() {
        guard let url = sidecarURL,
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Sidecar.self, from: data) {
            annotations = decoded.annotations
            collaborators = decoded.collaborators ?? [:]
            DebugConsole.shared.log("LOAD: \(annotations.count) annotations, \(collaborators.count) collaborators")
            if let t = decoded.theme { theme = t }
            if let s = decoded.fontScale { fontScale = s }
            if let w = decoded.readingWidth { readingWidth = w }
            if let f = decoded.readingFont { readingFont = f }
            if let b = decoded.bionicText { bionicText = b }
            if let baseline = decoded.lastSyncedText {
                lastSyncedText = baseline
            }
        }
    }

    func saveSidecar() {
        guard let url = sidecarURL else { return }
        DebugConsole.shared.log("SAVE: \(annotations.count) annotations")
        let baseline = (lastSyncedText != rawText) ? lastSyncedText : nil
        writeSidecar(to: url, annotations: annotations, lastSynced: baseline)
    }

    private func saveSidecar(forTab tab: DocumentTab) {
        let scheme = tab.fileURL.scheme?.lowercased()
        let url: URL?
        if scheme == "http" || scheme == "https" {
            url = Self.urlSidecarsDir()?
                .appendingPathComponent("\(Self.urlKey(for: tab.fileURL)).mindle.json")
        } else if scheme == "clipboard" {
            url = Self.clipboardSidecarsDir()?
                .appendingPathComponent("\(tab.fileURL.lastPathComponent).mindle.json")
        } else {
            url = tab.fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(tab.fileURL.lastPathComponent).mindle.json")
        }
        guard let url else { return }
        let baseline = (tab.lastSyncedText != tab.rawText) ? tab.lastSyncedText : nil
        writeSidecar(to: url, annotations: tab.annotations, lastSynced: baseline)
    }

    private func writeSidecar(to url: URL, annotations: [Annotation], lastSynced: String?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Auto-register the current user in the document's collaborator
        // registry. The disk write picks up the new entry from `collabs`
        // below, but we also have to mirror it back into the @Published
        // `collaborators` map — otherwise the UI sees a stale empty
        // registry and the conditional collab row on each annotation
        // card stays hidden until the file is closed and reopened.
        var collabs = collaborators
        let im = IdentityManager.shared
        if im.isConfigured {
            collabs[im.alias] = im.asSidecarCollaborator()
        }
        if collabs != collaborators {
            collaborators = collabs
        }
        let sidecar = Sidecar(
            annotations: annotations,
            theme: theme,
            fontScale: fontScale,
            lastSyncedText: lastSynced,
            collaborators: collabs.isEmpty ? nil : collabs,
            readingWidth: readingWidth == .narrow ? nil : readingWidth,
            readingFont: readingFont == .serif ? nil : readingFont,
            bionicText: bionicText ? true : nil
        )
        if let data = try? encoder.encode(sidecar) {
            // Stamp *before* the write so the FSEvents echo (which can
            // arrive almost synchronously) lands inside the suppression
            // window in reloadSidecarFromDisk.
            lastSelfSidecarWriteAt = Date()
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Collab Actions

    func resolveAnnotation(id: UUID, by user: String? = nil) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[idx].status = .resolved
        annotations[idx].resolvedBy = user ?? IdentityManager.shared.alias
        annotations[idx].resolvedAt = Date()
        DebugConsole.shared.log("Resolved annotation \(id.uuidString.prefix(8)) by \(annotations[idx].resolvedBy ?? "?")")
        saveSidecar()
    }

    func reopenAnnotation(id: UUID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[idx].status = .open
        annotations[idx].resolvedBy = nil
        annotations[idx].resolvedAt = nil
        saveSidecar()
    }

    func assignAnnotation(id: UUID, to assignee: String) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[idx].assignee = assignee
        DebugConsole.shared.log("Assigned \(id.uuidString.prefix(8)) → \(assignee)")
        saveSidecar()
    }

    func addLabel(to id: UUID, label: String) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        var existing = annotations[idx].labels ?? []
        if !existing.contains(label) {
            existing.append(label)
            annotations[idx].labels = existing
            DebugConsole.shared.log("Label +\(label) on \(id.uuidString.prefix(8))")
            saveSidecar()
        }
    }

    func removeLabel(from id: UUID, label: String) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[idx].labels?.removeAll { $0 == label }
        saveSidecar()
    }

    /// Toggle a reaction on an annotation (when `messageID` is nil) or
    /// on a thread message. Same (author, kind) pair is removed if
    /// present, otherwise appended. Author is the current user's alias
    /// — falls back to "user" when identity isn't configured (matches
    /// how `author` is stamped on pre-identity annotations).
    func toggleReaction(annotationID: UUID, messageID: UUID? = nil, kind: String) {
        let alias = IdentityManager.shared.isConfigured ? IdentityManager.shared.alias : "user"
        applyReactionToggle(in: &annotations, annotationID: annotationID, messageID: messageID, kind: kind, author: alias)
        DebugConsole.shared.log("REACT: \(kind) on \(annotationID.uuidString.prefix(8))\(messageID != nil ? "/msg" : "") by \(alias)")
        saveSidecar()
    }

    /// MCP-side: toggle a reaction on the annotation that lives on `path`.
    /// Looks across every tab in this store (active and inactive). Returns
    /// true if a matching annotation was found and the toggle applied.
    @discardableResult
    func toggleReaction(
        forPath path: String,
        annotationID: UUID,
        messageID: UUID? = nil,
        kind: String,
        author: String = "agent"
    ) -> Bool {
        let canonical = URL(fileURLWithPath: path).canonicalPath
        if let active = activeTabID,
           let i = tabs.firstIndex(where: { $0.id == active }),
           tabs[i].fileURL.canonicalPath == canonical {
            guard annotations.contains(where: { $0.id == annotationID }) else { return false }
            applyReactionToggle(in: &annotations, annotationID: annotationID, messageID: messageID, kind: kind, author: author)
            DebugConsole.shared.log("REACT: \(kind) on \(annotationID.uuidString.prefix(8))\(messageID != nil ? "/msg" : "") by \(author)")
            saveSidecar()
            return true
        }
        if let i = tabs.firstIndex(where: { $0.fileURL.canonicalPath == canonical }) {
            guard tabs[i].annotations.contains(where: { $0.id == annotationID }) else { return false }
            applyReactionToggle(in: &tabs[i].annotations, annotationID: annotationID, messageID: messageID, kind: kind, author: author)
            DebugConsole.shared.log("REACT: \(kind) on \(annotationID.uuidString.prefix(8))\(messageID != nil ? "/msg" : "") by \(author) (inactive tab)")
            saveSidecar(forTab: tabs[i])
            return true
        }
        return false
    }

    /// Shared in-place mutation. Same (author, kind) pair removes; otherwise
    /// appends. Compacts an emptied reactions array back to nil so the
    /// sidecar stays minimal.
    private func applyReactionToggle(
        in anns: inout [Annotation],
        annotationID: UUID,
        messageID: UUID?,
        kind: String,
        author: String
    ) {
        guard let i = anns.firstIndex(where: { $0.id == annotationID }) else { return }
        if let messageID {
            guard var thread = anns[i].thread,
                  let j = thread.firstIndex(where: { $0.id == messageID }) else { return }
            var existing = thread[j].reactions ?? []
            if let k = existing.firstIndex(where: { $0.author == author && $0.kind == kind }) {
                existing.remove(at: k)
            } else {
                existing.append(AnnotationReaction(author: author, kind: kind))
            }
            thread[j].reactions = existing.isEmpty ? nil : existing
            anns[i].thread = thread
        } else {
            var existing = anns[i].reactions ?? []
            if let k = existing.firstIndex(where: { $0.author == author && $0.kind == kind }) {
                existing.remove(at: k)
            } else {
                existing.append(AnnotationReaction(author: author, kind: kind))
            }
            anns[i].reactions = existing.isEmpty ? nil : existing
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
            var heading = ann.note.isEmpty ? "### Highlight" : "### Note"
            // PDF: surface the page so a printed export tells the reader
            // where the passage lived in the original document. 1-based
            // for human readability, matches the page chrome PDFView
            // shows on screen.
            if let pageIndex = ann.pageIndex {
                heading += " · Page \(pageIndex + 1)"
            }
            out.append(heading)
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
