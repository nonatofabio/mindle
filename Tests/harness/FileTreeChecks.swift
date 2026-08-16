import Foundation

func runFileTreeChecks() -> Int {
    let checks = Checks("FileTree")
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: ".build/test-fixtures/file-tree", isDirectory: true)
        .standardizedFileURL

    do {
        try? fileManager.removeItem(at: root)
        let alpha = root.appendingPathComponent("Alpha", isDirectory: true)
        let nested = alpha.appendingPathComponent("Nested", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        let hidden = root.appendingPathComponent(".Hidden", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hidden, withIntermediateDirectories: true)

        try "# A".write(to: alpha.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# B".write(to: nested.appendingPathComponent("b.markdown"), atomically: true, encoding: .utf8)
        try "text".write(to: root.appendingPathComponent("Beta.txt"), atomically: true, encoding: .utf8)
        try "pdf".write(to: root.appendingPathComponent("paper.PDF"), atomically: true, encoding: .utf8)
        try "ignored".write(to: empty.appendingPathComponent("ignored.json"), atomically: true, encoding: .utf8)
        try "# Hidden".write(to: hidden.appendingPathComponent("hidden.md"), atomically: true, encoding: .utf8)
        try "# MDX".write(to: root.appendingPathComponent("unsupported.mdx"), atomically: true, encoding: .utf8)

        let tree = try FileTreeBuilder.build(at: root)
        let rootNames = tree.children?.map(\.name) ?? []
        checks.equal(rootNames, ["Alpha", "Beta.txt", "paper.PDF"], "folders sort before files")
        checks.expect(!rootNames.contains("Empty"), "unsupported-only directory is pruned")
        checks.expect(!rootNames.contains(".Hidden"), "hidden directory is skipped")
        checks.expect(!rootNames.contains("unsupported.mdx"), "unsupported extension is skipped")

        let rows = FileTreeBuilder.visibleRows(in: tree, collapsedDirectories: [])
        checks.equal(
            rows.map(\.name),
            ["Alpha", "Nested", "b.markdown", "a.md", "Beta.txt", "paper.PDF"],
            "tree flattens in display order"
        )
        checks.equal(rows.map(\.depth), [0, 1, 2, 1, 0, 0], "row depths")
        checks.equal(Set(rows.map(\.id)).count, rows.count, "row identities are unique")

        let idsByURL = Dictionary(uniqueKeysWithValues: rows.map { ($0.url, $0.id) })
        let repeatedRows = FileTreeBuilder.visibleRows(in: tree, collapsedDirectories: [])
        checks.equal(repeatedRows.map(\.id), rows.map(\.id), "flattening preserves row identities")
        checks.expect(
            repeatedRows.allSatisfy { idsByURL[$0.url] == $0.id },
            "identity is derived from normalized file URL"
        )

        let collapsedRows = FileTreeBuilder.visibleRows(
            in: tree,
            collapsedDirectories: [alpha.standardizedFileURL]
        )
        checks.equal(
            collapsedRows.map(\.name),
            ["Alpha", "Beta.txt", "paper.PDF"],
            "collapsed directory hides descendants"
        )
        checks.equal(
            collapsedRows.map(\.id),
            [rows[0].id, rows[4].id, rows[5].id],
            "collapsing preserves unaffected row identities"
        )
        checks.expect(!collapsedRows[0].isExpanded, "collapsed state is carried by row model")

        checks.expect(
            FileTreeBuilder.isDescendant(nested.appendingPathComponent("b.markdown"), of: root),
            "nested file is inside root"
        )
        checks.expect(
            !FileTreeBuilder.isDescendant(
                URL(fileURLWithPath: root.path + "-other/note.md"),
                of: root
            ),
            "path-prefix sibling is outside root"
        )
        checks.expect(FileTreeBuilder.isDescendant(root, of: root), "root is its own descendant")
        checks.expect(FileTreeBuilder.isBrowsableFile(URL(fileURLWithPath: "note.mkd")), "mkd is supported")
        checks.expect(!FileTreeBuilder.isBrowsableFile(URL(fileURLWithPath: "note.mdx")), "mdx is unsupported")
    } catch {
        checks.expect(false, "fixture setup/build failed: \(error)")
    }

    try? fileManager.removeItem(at: root)
    print("FileTree: \(checks.passed) passed, \(checks.failures) failed")
    return checks.failures
}
