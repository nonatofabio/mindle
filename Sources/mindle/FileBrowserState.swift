import Combine
import Foundation

@MainActor
final class FileBrowserState: ObservableObject {
    private enum TreeBuildResult: Sendable {
        case success(FileNode)
        case failure(String)
    }

    @Published private(set) var rootURL: URL?
    @Published private(set) var rootDisplayName: String?
    @Published private(set) var tree: FileNode?
    @Published private(set) var rows: [FileTreeRowModel] = []
    @Published private(set) var selectedURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var gitMetadata = GitMetadataSnapshot.empty

    private var collapsedDirectories: Set<URL> = []
    private var refreshTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var treeWorker: Task<TreeBuildResult, Never>?
    private var metadataWorker: Task<GitMetadataSnapshot, Never>?
    private var refreshGeneration = 0

    func setRoot(_ url: URL?) {
        let normalized = Self.normalized(url)
        guard rootURL != normalized else {
            refresh()
            return
        }
        refreshTask?.cancel()
        metadataTask?.cancel()
        treeWorker?.cancel()
        metadataWorker?.cancel()
        rootURL = normalized
        rootDisplayName = normalized?.lastPathComponent
        tree = nil
        rows = []
        gitMetadata = .empty
        errorMessage = nil
        collapsedDirectories.removeAll()
        refresh()
    }

    func beginRemoteLoad(profile: SSHProfile) -> Int {
        refreshGeneration += 1
        cancelWorkers()
        rootURL = profile.rootTarget.sourceURL
        rootDisplayName = profile.name
        tree = nil
        rows = []
        selectedURL = nil
        gitMetadata = .empty
        errorMessage = nil
        collapsedDirectories.removeAll()
        isLoading = true
        return refreshGeneration
    }

    func finishRemoteLoad(
        profile: SSHProfile,
        listing: RemoteDocumentListing,
        generation: Int
    ) -> Bool {
        guard generation == refreshGeneration,
              rootURL == profile.rootTarget.sourceURL else { return false }
        rootURL = listing.root.sourceURL
        tree = FileTreeBuilder.buildRemote(root: listing.root, files: listing.files)
        isLoading = false
        errorMessage = nil
        rebuildRows()
        return true
    }

    func failRemoteLoad(profile: SSHProfile, message: String, generation: Int) -> Bool {
        guard generation == refreshGeneration,
              rootURL == profile.rootTarget.sourceURL else { return false }
        tree = nil
        rows = []
        isLoading = false
        errorMessage = message
        return true
    }

    func refresh() {
        refreshTask?.cancel()
        metadataTask?.cancel()
        treeWorker?.cancel()
        metadataWorker?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration

        guard let rootURL else {
            tree = nil
            rows = []
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        let includeGitChanges = BrowserDisplaySettings.showGitChanges()
        let includeLastEdited = BrowserDisplaySettings.showLastEdited()

        let treeWorker = Task.detached(priority: .userInitiated) {
            do {
                return TreeBuildResult.success(
                    try PerformanceTrace.measure("FileTreeBuild") {
                        try FileTreeBuilder.build(at: rootURL)
                    }
                )
            } catch {
                return TreeBuildResult.failure(error.localizedDescription)
            }
        }
        self.treeWorker = treeWorker
        refreshTask = Task { [weak self] in
            let result = await treeWorker.value

            guard let self,
                  !Task.isCancelled,
                  generation == self.refreshGeneration else { return }

            self.isLoading = false
            switch result {
            case .success(let tree):
                self.tree = tree
                self.rebuildRows()
            case .failure(let errorMessage):
                self.metadataTask?.cancel()
                self.metadataWorker?.cancel()
                self.tree = nil
                self.rows = []
                self.gitMetadata = .empty
                self.errorMessage = errorMessage
            }
        }

        guard includeGitChanges || includeLastEdited else {
            gitMetadata = .empty
            return
        }
        let metadataWorker = Task.detached(priority: .utility) {
            PerformanceTrace.measure("GitMetadataBuild") {
                GitMetadataCollector.collect(
                    for: rootURL,
                    includeChanges: includeGitChanges,
                    includeLastEdited: includeLastEdited
                )
            }
        }
        self.metadataWorker = metadataWorker
        metadataTask = Task { [weak self] in
            let metadata = await metadataWorker.value

            guard let self,
                  !Task.isCancelled,
                  generation == self.refreshGeneration else { return }
            self.gitMetadata = metadata
        }
    }

    func setSelectedURL(_ url: URL?) {
        let normalized = Self.normalized(url)
        if selectedURL != normalized {
            selectedURL = normalized
        }
    }

    func toggleDirectory(_ url: URL) {
        let normalized = Self.normalized(url)!
        if collapsedDirectories.contains(normalized) {
            collapsedDirectories.remove(normalized)
        } else {
            collapsedDirectories.insert(normalized)
        }
        rebuildRows()
    }

    func cancelAll() {
        refreshGeneration += 1
        cancelWorkers()
        isLoading = false
    }

    private func cancelWorkers() {
        refreshTask?.cancel()
        metadataTask?.cancel()
        treeWorker?.cancel()
        metadataWorker?.cancel()
        refreshTask = nil
        metadataTask = nil
        treeWorker = nil
        metadataWorker = nil
    }

    private static func normalized(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return url.isFileURL ? url.standardizedFileURL : url
    }

    private func rebuildRows() {
        rows = PerformanceTrace.measure("FileTreeFlatten") {
            FileTreeBuilder.visibleRows(
                in: tree,
                collapsedDirectories: collapsedDirectories
            )
        }
        PerformanceTrace.fileTreePublished(rowCount: rows.count)
    }
}
