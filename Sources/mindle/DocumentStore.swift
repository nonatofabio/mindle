import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ReaderTheme: String, CaseIterable, Codable {
    case light, sepia, dark
}

struct Annotation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String        // the selected passage verbatim
    var prefix: String      // ~32 chars before
    var suffix: String      // ~32 chars after
    var note: String
    var createdAt: Date = Date()
}

struct FileNode: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [FileNode]?   // nil = leaf file; non-nil = directory
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var fileURL: URL?
    @Published var rawText: String = ""
    @Published var annotations: [Annotation] = []

    @Published var theme: ReaderTheme = .sepia
    @Published var fontScale: Double = 1.0
    @Published var showAnnotations: Bool = false
    @Published var showFileBrowser: Bool = false
    @Published var fileTree: FileNode? = nil

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
    @Published var editingAnnotationID: UUID? = nil

    // Bumped to trigger a PDF export in the WKWebView coordinator.
    @Published var pdfExportRequestedAt: Date? = nil

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

            closeSearch()
            self.fileURL = url
            self.rawText = text
            self.annotations = []
            self.loadSidecar()
            if shouldRebuildTree {
                refreshFileTree()
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSSound.beep()
        }
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
        // Toggle off if an annotation already exists with identical text+context
        if let i = annotations.firstIndex(where: {
            $0.text == selectionText && $0.prefix == selectionPrefix && $0.suffix == selectionSuffix
        }) {
            annotations.remove(at: i)
        } else {
            annotations.append(Annotation(
                text: selectionText,
                prefix: selectionPrefix,
                suffix: selectionSuffix,
                note: ""
            ))
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
            editingAnnotationID = ann.id
            focusedAnnotation = ann.id
            saveSidecar()
        }
    }

    func updateNote(id: UUID, note: String) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].note = note
        saveSidecar()
    }

    func delete(id: UUID) {
        annotations.removeAll { $0.id == id }
        saveSidecar()
    }

    func jumpTo(id: UUID) {
        focusedAnnotation = id
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
        }
    }

    func saveSidecar() {
        guard let url = sidecarURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sidecar = Sidecar(annotations: annotations, theme: theme, fontScale: fontScale)
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
