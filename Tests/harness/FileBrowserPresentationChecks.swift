import Foundation

func runFileBrowserPresentationChecks() -> Int {
    let checks = Checks("FileBrowserPresentation")
    let root = URL(fileURLWithPath: "/Users/reader/Field Notes", isDirectory: true)
    let file = root.appendingPathComponent("chapter.md")
    let populatedTree = FileNode(
        url: root,
        name: "Field Notes",
        isDirectory: true,
        children: [
            FileNode(url: file, name: "chapter.md", isDirectory: false, children: nil)
        ]
    )
    let emptyTree = FileNode(
        url: root,
        name: "Field Notes",
        isDirectory: true,
        children: []
    )

    checks.equal(
        FileBrowserPresentation.headerTitle(rootURL: root),
        "Field Notes",
        "header uses the scoped folder name"
    )
    checks.equal(
        FileBrowserPresentation.headerTitle(rootURL: nil),
        "Files",
        "header falls back when no scope is available"
    )
    checks.equal(
        FileBrowserPresentation.state(tree: nil, isLoading: true, errorMessage: nil),
        .loading,
        "initial scan shows loading"
    )
    checks.equal(
        FileBrowserPresentation.state(
            tree: nil,
            isLoading: false,
            errorMessage: "Permission denied."
        ),
        .error("Permission denied."),
        "scan failures show an error"
    )
    checks.equal(
        FileBrowserPresentation.state(
            tree: populatedTree,
            isLoading: true,
            errorMessage: nil
        ),
        .populated,
        "refresh preserves populated content"
    )
    checks.equal(
        FileBrowserPresentation.state(
            tree: emptyTree,
            isLoading: false,
            errorMessage: nil
        ),
        .empty,
        "empty folders show the empty state"
    )

    print("FileBrowserPresentation: \(checks.passed) passed, \(checks.failures) failed")
    return checks.failures
}
