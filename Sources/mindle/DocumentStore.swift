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

@MainActor
final class DocumentStore: ObservableObject {
    @Published var fileURL: URL?
    @Published var rawText: String = ""
    @Published var annotations: [Annotation] = []

    @Published var theme: ReaderTheme = .sepia
    @Published var fontScale: Double = 1.0
    @Published var showAnnotations: Bool = false

    // Selection from the web view
    @Published private(set) var selectionText: String = ""
    private var selectionPrefix: String = ""
    private var selectionSuffix: String = ""

    @Published var focusedAnnotation: UUID? = nil
    @Published var editingAnnotationID: UUID? = nil

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
            self.fileURL = url
            self.rawText = text
            self.annotations = []
            self.loadSidecar()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSSound.beep()
        }
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
}
