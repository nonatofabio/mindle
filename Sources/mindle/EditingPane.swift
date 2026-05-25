import SwiftUI
import AppKit

/// Whole-document editor for a markdown file. Replaces the reader pane
/// (WebReaderView) when `store.editingBlock` is set; reader returns
/// when nil. Bare raw markdown source in a monospace font — Mindle
/// isn't trying to be a markdown editor; this is the smallest surface
/// that lets the user fix a thing in-place without switching apps.
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
                    previewPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            actionRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(c.surface)
        }
        .background(c.background)
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

    private var previewPane: some View {
        let c = store.theme.colors
        return ScrollView {
            if let rendered = try? AttributedString(
                markdown: draft,
                options: .init(interpretedSyntax: .full)
            ) {
                Text(rendered)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(c.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                Text("Couldn't render preview — markdown may have invalid syntax.")
                    .font(.system(size: 12, design: .serif).italic())
                    .foregroundStyle(c.muted)
                    .padding()
            }
        }
        .background(c.background)
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
        store.commitEdit(draft: draft)
    }
}
