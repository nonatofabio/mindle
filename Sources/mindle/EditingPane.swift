import SwiftUI
import AppKit

/// Slide-down editor for a single markdown block. Shown as an overlay
/// on `ReaderPane` when `store.editingBlock` is set; closed when nil.
/// Bare raw markdown source in a monospace font — Mindle isn't trying
/// to be a markdown editor; this is the smallest surface that lets the
/// user fix a thing in-place without switching to vim / iA Writer.
///
/// Stage 1 scope: source view only (no preview). Three buttons —
/// Save / Preview / Cancel — wired to a no-op Save and Preview for now.
/// Preview swap lands in stage 2, save write-through in stage 3.
struct EditingPane: View {
    let block: EditingBlock
    @EnvironmentObject var store: DocumentStore
    @State private var draft: String = ""
    @State private var mode: EditingMode = .source
    @FocusState private var editorFocused: Bool

    init(block: EditingBlock) {
        self.block = block
        _draft = State(initialValue: block.originalText)
    }

    enum EditingMode {
        case source
        case preview
    }

    var body: some View {
        let c = store.theme.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(c.accent)
                Text("Editing passage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(c.text)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(c.surface)

            Divider()

            Group {
                switch mode {
                case .source:
                    sourceEditor
                case .preview:
                    previewPlaceholder
                }
            }
            .frame(minHeight: 200, idealHeight: 280, maxHeight: 360)

            Divider()

            actionRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(c.surface)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(c.background)
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(c.rule.opacity(0.4), lineWidth: 0.5)
        )
        .onAppear {
            // Defer focus by one runloop pass — TextEditor isn't in the
            // view tree until SwiftUI has built the body.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                editorFocused = true
            }
        }
    }

    private var sourceEditor: some View {
        let c = store.theme.colors
        return TextEditor(text: $draft)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(c.text)
            .scrollContentBackground(.hidden)
            .background(c.background)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .focused($editorFocused)
    }

    private var previewPlaceholder: some View {
        let c = store.theme.colors
        return VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24, weight: .ultraLight))
                .foregroundStyle(c.muted.opacity(0.7))
            Text("Preview lands in stage 2.")
                .font(.system(size: 12, design: .serif).italic())
                .foregroundStyle(c.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionRow: some View {
        let c = store.theme.colors
        let isSource = (mode == .source)
        return HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(c.muted)
            Button(isSource ? "Preview" : "Edit") {
                mode = isSource ? .preview : .source
            }
            .foregroundStyle(c.accent)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .tint(c.accent)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func cancel() {
        store.editingBlock = nil
    }

    private func save() {
        // Stage 3 lands the actual write-through. For stage 1 we just
        // close the editor so the flow round-trips visually.
        store.editingBlock = nil
    }
}
