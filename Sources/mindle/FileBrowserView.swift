import SwiftUI

struct FileBrowserSidebar: View {
    @ObservedObject var browser: FileBrowserState
    let theme: ReaderTheme
    let onRefresh: () -> Void
    let onOpen: (URL) -> Void

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(c.accent)
                Text(browser.rootURL?.lastPathComponent ?? "Files")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(c.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(browser.rootURL?.path ?? "Files")
                Spacer()
                Button(action: onRefresh) {
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

            if browser.isLoading && browser.tree == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = browser.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .ultraLight))
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(c.muted)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !browser.rows.isEmpty {
                ScrollView {
                    FileBrowserRowStack(
                        rows: browser.rows,
                        selectedURL: browser.selectedURL,
                        gitMetadata: browser.gitMetadata,
                        theme: theme,
                        onToggle: browser.toggleDirectory,
                        onOpen: onOpen
                    )
                    .padding(.vertical, 6)
                }
                .accessibilityIdentifier("file-browser-scroll")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(c.muted.opacity(0.7))
                    Text("No supported files\nin this directory.")
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

private struct FileBrowserRowStack: View {
    let rows: [FileTreeRowModel]
    let selectedURL: URL?
    let gitMetadata: GitMetadataSnapshot
    let theme: ReaderTheme
    let onToggle: (URL) -> Void
    let onOpen: (URL) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                let metadata = gitMetadata.files[row.url]
                FileTreeRow(
                    row: row,
                    isCurrent: selectedURL == row.url,
                    changes: metadata?.changes,
                    lastEditedAt: metadata?.lastEditedAt,
                    theme: theme,
                    onToggle: onToggle,
                    onOpen: onOpen
                )
                .equatable()
            }
        }
    }
}

struct FileTreeRow: View, Equatable {
    let row: FileTreeRowModel
    let isCurrent: Bool
    let changes: GitFileChanges?
    let lastEditedAt: Date?
    let theme: ReaderTheme
    let onToggle: (URL) -> Void
    let onOpen: (URL) -> Void

    static func == (lhs: FileTreeRow, rhs: FileTreeRow) -> Bool {
        lhs.row == rhs.row
            && lhs.isCurrent == rhs.isCurrent
            && lhs.changes == rhs.changes
            && lhs.lastEditedAt == rhs.lastEditedAt
            && lhs.theme == rhs.theme
    }

    var body: some View {
        let c = theme.colors
        if row.kind == .directory {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    onToggle(row.url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(c.muted)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(c.muted)
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(c.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(row.depth) * 14 + 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.name)
            .accessibilityIdentifier("file-browser-row-\(row.url.path)")
        } else {
            Button {
                onOpen(row.url)
            } label: {
                HStack(spacing: 6) {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(isCurrent ? c.accent : c.muted)
                    Text(row.name)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(c.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let changes {
                        GitChangesBadge(changes: changes, theme: theme)
                    }
                    if let lastEditedAt {
                        LastEditedBadge(date: lastEditedAt, theme: theme)
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 14 + 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? c.accent.opacity(theme == .dark ? 0.28 : 0.22) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.name)
            .accessibilityValue(isCurrent ? "Selected" : "")
            .accessibilityIdentifier("file-browser-row-\(row.url.path)")
        }
    }

    private struct GitChangesBadge: View {
        let changes: GitFileChanges
        let theme: ReaderTheme

        var body: some View {
            let c = theme.colors
            Text(changes.badgeText)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(changes.isUntracked ? c.accent : c.text.opacity(0.78))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(c.surface.opacity(0.8))
                .clipShape(Capsule())
                .help(changes.isUntracked ? "Untracked file" : "Git working-tree additions and deletions")
        }
    }

    private struct LastEditedBadge: View {
        let date: Date
        let theme: ReaderTheme

        var body: some View {
            let c = theme.colors
            Text(GitLastEditedFormatter.badgeText(since: date))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(c.muted)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(c.surface.opacity(0.65))
                .clipShape(Capsule())
                .help("Last committed \(date.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}
