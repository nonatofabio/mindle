import Foundation

struct FileNode: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [FileNode]?
}

struct FileTreeRowModel: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
    }

    var id: URL { url }
    let url: URL
    let name: String
    let depth: Int
    let kind: Kind
    let isExpanded: Bool
}

enum FileTreeBuilder {
    static let browsableExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "pdf"
    ]

    static func isBrowsableFile(_ url: URL) -> Bool {
        browsableExtensions.contains(url.pathExtension.lowercased())
    }

    static func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let ancestorPath = ancestor.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        if urlPath == ancestorPath { return true }
        let prefix = ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/"
        return urlPath.hasPrefix(prefix)
    }

    static func build(at root: URL, fileManager: FileManager = .default) throws -> FileNode {
        try Task.checkCancellation()
        let normalizedRoot = root.standardizedFileURL
        return FileNode(
            url: normalizedRoot,
            name: normalizedRoot.lastPathComponent,
            isDirectory: true,
            children: try buildChildren(
                contents(of: normalizedRoot, fileManager: fileManager),
                fileManager: fileManager
            )
        )
    }

    static func visibleRows(
        in tree: FileNode?,
        collapsedDirectories: Set<URL>
    ) -> [FileTreeRowModel] {
        guard let children = tree?.children else { return [] }
        var rows: [FileTreeRowModel] = []
        appendRows(
            children,
            depth: 0,
            collapsedDirectories: collapsedDirectories,
            to: &rows
        )
        return rows
    }

    private static func buildChildren(
        _ entries: [URL],
        fileManager: FileManager
    ) throws -> [FileNode] {
        var children: [FileNode] = []
        for entry in entries {
            try Task.checkCancellation()
            let normalizedEntry = entry.standardizedFileURL
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                let nestedEntries: [URL]
                do {
                    nestedEntries = try contents(of: normalizedEntry, fileManager: fileManager)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
                let nestedChildren = try buildChildren(nestedEntries, fileManager: fileManager)
                if !nestedChildren.isEmpty {
                    children.append(FileNode(
                        url: normalizedEntry,
                        name: normalizedEntry.lastPathComponent,
                        isDirectory: true,
                        children: nestedChildren
                    ))
                }
            } else if isBrowsableFile(normalizedEntry) {
                children.append(FileNode(
                    url: normalizedEntry,
                    name: normalizedEntry.lastPathComponent,
                    isDirectory: false,
                    children: nil
                ))
            }
        }

        children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return children
    }

    private static func contents(
        of directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    private static func appendRows(
        _ nodes: [FileNode],
        depth: Int,
        collapsedDirectories: Set<URL>,
        to rows: inout [FileTreeRowModel]
    ) {
        for node in nodes {
            let isExpanded = node.isDirectory
                && !collapsedDirectories.contains(node.url.standardizedFileURL)
            rows.append(FileTreeRowModel(
                url: node.url,
                name: node.name,
                depth: depth,
                kind: node.isDirectory ? .directory : .file,
                isExpanded: isExpanded
            ))
            if isExpanded, let children = node.children {
                appendRows(
                    children,
                    depth: depth + 1,
                    collapsedDirectories: collapsedDirectories,
                    to: &rows
                )
            }
        }
    }
}
