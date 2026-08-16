import SwiftUI

struct FileBrowserSidebarContent: View {
    let rootURL: URL?
    let tree: FileNode?
    let selectedURL: URL?
    let isLoading: Bool
    let errorMessage: String?
    let highlightActiveFile: Bool
    let theme: ReaderTheme
    let onRefresh: () -> Void
    let onOpen: (URL) -> Void

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(c.accent)
                Text(FileBrowserPresentation.headerTitle(rootURL: rootURL))
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(c.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rootURL?.path ?? "Files")
                Spacer()
                Button(action: onRefresh) {
                    Group {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(c.muted)
                .disabled(isLoading)
                .help(isLoading ? "Refreshing file list" : "Refresh file list")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Rectangle().fill(c.rule.opacity(0.4)).frame(height: 0.5)

            switch FileBrowserPresentation.state(
                tree: tree,
                isLoading: isLoading,
                errorMessage: errorMessage
            ) {
            case .loading:
                FileBrowserLoadingState(theme: theme)
            case .error(let message):
                FileBrowserErrorState(message: message, theme: theme, onRetry: onRefresh)
            case .populated:
                ScrollView {
                    // Eager rows keep the tree's measured height stable when
                    // the active file or tab bar changes, avoiding #36's
                    // apparent selection jump.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tree?.children ?? []) { child in
                            FileTreeRow(
                                node: child,
                                depth: 0,
                                selectedURL: selectedURL,
                                highlightActiveFile: highlightActiveFile,
                                theme: theme,
                                onOpen: onOpen
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
            case .empty:
                FileBrowserEmptyState(theme: theme)
            }
        }
        .background(c.sidebar)
    }
}

private struct FileBrowserLoadingState: View {
    let theme: ReaderTheme

    var body: some View {
        let c = theme.colors
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for supported files…")
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(c.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileBrowserErrorState: View {
    let message: String
    let theme: ReaderTheme
    let onRetry: () -> Void

    var body: some View {
        let c = theme.colors
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .ultraLight))
                .foregroundStyle(c.muted)
            Text("Couldn’t load this folder")
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(c.text)
            Text(message)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(c.muted)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderless)
                .foregroundStyle(c.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileBrowserEmptyState: View {
    let theme: ReaderTheme

    var body: some View {
        let c = theme.colors
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(c.muted.opacity(0.7))
            Text("No supported files\nin this folder.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12, design: .serif).italic())
                .foregroundStyle(c.muted)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    let selectedURL: URL?
    let highlightActiveFile: Bool
    let theme: ReaderTheme
    let onOpen: (URL) -> Void
    @State private var isExpanded = true

    var body: some View {
        let c = theme.colors
        if node.isDirectory {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isExpanded.toggle()
                }
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
                    FileTreeRow(
                        node: child,
                        depth: depth + 1,
                        selectedURL: selectedURL,
                        highlightActiveFile: highlightActiveFile,
                        theme: theme,
                        onOpen: onOpen
                    )
                }
            }
        } else {
            let isCurrent = selectedURL?.standardizedFileURL == node.url.standardizedFileURL
            let isHighlighted = highlightActiveFile && isCurrent
            Button {
                onOpen(node.url)
            } label: {
                HStack(spacing: 6) {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(isHighlighted ? c.accent : c.muted)
                    Text(node.name)
                        .font(.system(
                            size: 12,
                            weight: isHighlighted ? .medium : .regular,
                            design: .serif
                        ))
                        .foregroundStyle(c.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(c.accent.opacity(theme == .dark ? 0.28 : 0.22))
                            .padding(.horizontal, 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
