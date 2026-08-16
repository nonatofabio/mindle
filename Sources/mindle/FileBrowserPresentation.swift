import Foundation

struct FileNode: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [FileNode]?
}

enum FileBrowserPresentationState: Equatable {
    case loading
    case error(String)
    case populated
    case empty
}

enum FileBrowserPresentation {
    static func headerTitle(rootURL: URL?) -> String {
        guard let title = rootURL?.lastPathComponent, !title.isEmpty else {
            return "Files"
        }
        return title
    }

    static func state(
        tree: FileNode?,
        isLoading: Bool,
        errorMessage: String?
    ) -> FileBrowserPresentationState {
        if isLoading && tree == nil {
            return .loading
        }
        if let errorMessage {
            return .error(errorMessage)
        }
        if let children = tree?.children, !children.isEmpty {
            return .populated
        }
        return .empty
    }
}
