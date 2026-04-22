import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        let c = store.theme.colors
        ZStack {
            // No .ignoresSafeArea() here — letting the toolbar safe-area
            // stay clear exposes macOS's default unified-toolbar material
            // (the translucent "glass" on modern Macs).
            c.background

            if store.fileURL == nil {
                EmptyStateView()
            } else {
                HSplitView {
                    if store.showFileBrowser {
                        FileBrowserSidebar()
                            .frame(minWidth: 200, idealWidth: 260, maxWidth: 400)
                    }
                    ReaderPane()
                        .frame(minWidth: 480)
                    if store.showAnnotations {
                        AnnotationsSidebar()
                            .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.openWithPanel() } label: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(c.text)
                }
                .help("Open a Markdown file (⌘O)")
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.showFileBrowser.toggle()
                    }
                    if store.showFileBrowser && store.fileTree == nil {
                        store.refreshFileTree()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(store.showFileBrowser ? c.accent : c.muted)
                }
                .help("Toggle files (⌘⇧F)")
                .disabled(store.fileURL == nil)
            }

            ToolbarItem(placement: .principal) {
                Text(store.fileURL?.lastPathComponent ?? "Mindle")
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundStyle(c.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.showAnnotations = true
                    store.highlightSelection()
                } label: {
                    Image(systemName: "highlighter")
                        .foregroundStyle(store.hasSelection ? c.accent : c.muted.opacity(0.5))
                }
                .disabled(!store.hasSelection)
                .help("Highlight selection (⌘⇧H)")

                Button {
                    store.showAnnotations = true
                    store.addNoteToSelection()
                } label: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(store.hasSelection ? c.accent : c.muted.opacity(0.5))
                }
                .disabled(!store.hasSelection)
                .help("Add note to selection (⌘⇧N)")

                Button { store.fontScale = max(0.75, store.fontScale - 0.05) } label: {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(c.text)
                }
                .help("Decrease text size (⌘-)")

                Button { store.fontScale = min(1.6, store.fontScale + 0.05) } label: {
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(c.text)
                }
                .help("Increase text size (⌘+)")

                Button { store.toggleTheme() } label: {
                    Image(systemName: themeIcon(store.theme))
                        .foregroundStyle(c.text)
                }
                .help("Cycle theme — light / sepia / dark (⌘⇧T)")

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.showAnnotations.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(store.showAnnotations ? c.accent : c.muted)
                }
                .help("Toggle annotations (⌘⇧A)")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            if let p = providers.first {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in store.open(url: url) }
                    }
                }
                return true
            }
            return false
        }
    }

    private func themeIcon(_ t: ReaderTheme) -> String {
        switch t {
        case .light: return "sun.max"
        case .sepia: return "book.closed"
        case .dark:  return "moon.stars"
        }
    }
}

// MARK: - Button styles

struct ToolChipStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 0.5)
            )
    }
}

struct ToolIconStyle: ButtonStyle {
    let tint: Color
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(enabled ? tint : tint.opacity(0.35))
            .frame(width: 30, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? tint.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        let c = store.theme.colors
        VStack(spacing: 20) {
            Image(systemName: "book.pages")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(c.muted)
            Text("Mindle")
                .font(.system(size: 32, weight: .light, design: .serif))
                .foregroundStyle(c.text)
            Text("A quiet place to read Markdown.")
                .font(.system(size: 14, design: .serif).italic())
                .foregroundStyle(c.muted)
            Button("Open a File…") { store.openWithPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            Text("…or drop a .md file onto this window")
                .font(.system(size: 11))
                .foregroundStyle(c.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reader

struct ReaderPane: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        let c = store.theme.colors
        ZStack(alignment: .top) {
            WebReaderView()
                .background(c.background)

            if store.showSearch {
                SearchBar()
                    .padding(.top, 10)
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

struct SearchBar: View {
    @EnvironmentObject var store: DocumentStore
    @FocusState private var queryFocused: Bool

    var body: some View {
        let c = store.theme.colors
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(c.muted)

            TextField("Find in document", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(c.text)
                .focused($queryFocused)
                .frame(minWidth: 180)
                .onSubmit { store.nextMatch() }

            if !store.searchQuery.isEmpty {
                Text(store.searchTotal == 0 ? "No matches" : "\(store.searchCurrent) of \(store.searchTotal)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(c.muted)
                    .frame(minWidth: 70, alignment: .trailing)
            }

            Button { store.previousMatch() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(c.muted)
            .disabled(store.searchTotal == 0)
            .help("Previous match (⌘⇧G)")

            Button { store.nextMatch() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(c.muted)
            .disabled(store.searchTotal == 0)
            .help("Next match (↩ or ⌘G)")

            Button { store.closeSearch() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(c.muted)
            .keyboardShortcut(.cancelAction)
            .help("Close (⎋)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(c.surface)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(c.rule.opacity(0.5), lineWidth: 0.5)
        )
        .frame(maxWidth: 420)
        .onAppear { queryFocused = true }
        .onChange(of: store.showSearch) { _, isShowing in
            if isShowing { queryFocused = true }
        }
    }
}

// MARK: - Annotations sidebar

struct AnnotationsSidebar: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        let c = store.theme.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(c.accent)
                Text("Annotations")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(c.text)
                Spacer()
                Text("\(store.annotations.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(c.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(c.muted.opacity(0.15))
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Rectangle().fill(c.rule.opacity(0.4)).frame(height: 0.5)

            if store.annotations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(c.muted.opacity(0.7))
                    Text("Select text, then press the highlighter\nor ⌘⇧H to mark a passage.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, design: .serif).italic())
                        .foregroundStyle(c.muted)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.annotations) { ann in
                            AnnotationCard(annotation: ann)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(c.sidebar)
    }
}

struct AnnotationCard: View {
    let annotation: Annotation
    @EnvironmentObject var store: DocumentStore
    @State private var noteDraft: String = ""
    @State private var isEditing: Bool = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        let c = store.theme.colors
        let isFocused = store.focusedAnnotation == annotation.id
        let dotColor: Color = annotation.note.isEmpty ? c.highlight : c.highlightNote

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(annotation.note.isEmpty ? "Highlight" : "Note")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(c.muted)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Button {
                    store.jumpTo(id: annotation.id)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(c.muted)
                .help("Scroll to this passage")

                Button {
                    store.delete(id: annotation.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(c.muted)
                .help("Delete")
            }

            Text(annotation.text)
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(c.text)
                .lineLimit(4)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(dotColor.opacity(0.9))
                        .frame(width: 2)
                }

            if isEditing || !annotation.note.isEmpty {
                TextEditor(text: $noteDraft)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(c.text)
                    .scrollContentBackground(.hidden)
                    .background(c.background.opacity(0.5))
                    .frame(minHeight: 54, maxHeight: 160)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(c.muted.opacity(isEditing ? 0.5 : 0.2), lineWidth: 0.5)
                    )
                    .focused($noteFocused)
                    .onChange(of: noteDraft) { _, newValue in
                        store.updateNote(id: annotation.id, note: newValue)
                    }

                if isEditing {
                    HStack {
                        Spacer()
                        Button("Done") {
                            isEditing = false
                            noteFocused = false
                            store.editingAnnotationID = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(c.accent)
                    }
                }
            } else {
                Button {
                    isEditing = true
                    noteFocused = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add a note")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(c.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(c.surface)
                .shadow(color: Color.black.opacity(isFocused ? 0.10 : 0.04), radius: isFocused ? 6 : 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isFocused ? c.accent.opacity(0.5) : c.rule.opacity(0.35), lineWidth: 0.5)
        )
        .onAppear {
            noteDraft = annotation.note
            if store.editingAnnotationID == annotation.id {
                isEditing = true
                noteFocused = true
            }
        }
        .onChange(of: annotation.note) { _, newValue in
            if newValue != noteDraft { noteDraft = newValue }
        }
        .onChange(of: store.editingAnnotationID) { _, newValue in
            if newValue == annotation.id {
                isEditing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    noteFocused = true
                }
            }
        }
    }
}

// MARK: - File browser sidebar

struct FileBrowserSidebar: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        let c = store.theme.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(c.accent)
                Text("Files")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(c.text)
                Spacer()
                Button {
                    store.refreshFileTree()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(c.muted)
                .help("Refresh file list")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Rectangle().fill(c.rule.opacity(0.4)).frame(height: 0.5)

            if let tree = store.fileTree, let children = tree.children, !children.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(children) { child in
                            FileTreeRow(node: child, depth: 0)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(c.muted.opacity(0.7))
                    Text("No markdown files\nin this directory.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, design: .serif).italic())
                        .foregroundStyle(c.muted)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(c.sidebar)
    }
}

struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    @EnvironmentObject var store: DocumentStore
    @State private var isExpanded: Bool = true

    var body: some View {
        let c = store.theme.colors
        if node.isDirectory {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(c.muted)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(c.muted)
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(c.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(node.children ?? []) { child in
                    FileTreeRow(node: child, depth: depth + 1)
                }
            }
        } else {
            let isCurrent = store.fileURL?.standardizedFileURL == node.url.standardizedFileURL
            Button {
                store.open(url: node.url)
            } label: {
                HStack(spacing: 6) {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(isCurrent ? c.accent : c.muted)
                    Text(node.name)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(c.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? c.accent.opacity(0.14) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
