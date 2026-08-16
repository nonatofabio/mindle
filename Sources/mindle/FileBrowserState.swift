import Combine
import Foundation

@MainActor
final class FileBrowserState: ObservableObject {
    typealias TreeBuilder = @Sendable (URL) throws -> FileNode
    typealias MetadataBuilder = @Sendable (URL) async -> GitMetadataSnapshot

    private enum TreeBuildResult: Sendable {
        case success(FileNode)
        case failure(String)
    }

    @Published private(set) var rootURL: URL?
    @Published private(set) var tree: FileNode?
    @Published private(set) var rows: [FileTreeRowModel] = []
    @Published private(set) var selectedURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var gitMetadata = GitMetadataSnapshot.empty

    private let treeBuilder: TreeBuilder
    private let metadataBuilder: MetadataBuilder
    private var collapsedDirectories: Set<URL> = []
    private var refreshTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var treeWorker: Task<TreeBuildResult, Never>?
    private var metadataWorker: Task<GitMetadataSnapshot, Never>?
    private var refreshGeneration = 0

    init(
        treeBuilder: @escaping TreeBuilder = { try FileTreeBuilder.build(at: $0) },
        metadataBuilder: @escaping MetadataBuilder = { await GitMetadataCollector.collect(for: $0) }
    ) {
        self.treeBuilder = treeBuilder
        self.metadataBuilder = metadataBuilder
    }

    func setRoot(_ url: URL?) {
        let normalized = Self.normalized(url)
        guard rootURL != normalized else {
            refresh()
            return
        }

        refreshGeneration += 1
        cancelWorkers()
        rootURL = normalized
        tree = nil
        updateRows([])
        selectedURL = nil
        gitMetadata = .empty
        errorMessage = nil
        collapsedDirectories.removeAll()
        startRefresh(generation: refreshGeneration)
    }

    func refresh() {
        refreshGeneration += 1
        cancelWorkers()
        startRefresh(generation: refreshGeneration)
    }

    func setSelectedURL(_ url: URL?) {
        let normalized = Self.normalized(url)
        if selectedURL != normalized {
            selectedURL = normalized
        }
    }

    func toggleDirectory(_ url: URL) {
        let normalized = url.standardizedFileURL
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

    private func startRefresh(generation: Int) {
        guard let rootURL else {
            tree = nil
            updateRows([])
            selectedURL = nil
            gitMetadata = .empty
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        let treeBuilder = self.treeBuilder
        let treeWorker = Task.detached(priority: .userInitiated) {
            do {
                return TreeBuildResult.success(
                    try PerformanceTrace.measure("FileTreeBuild") {
                        try treeBuilder(rootURL)
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
                if self.tree != tree {
                    self.tree = tree
                }
                self.rebuildRows()
            case .failure(let message):
                self.metadataTask?.cancel()
                self.metadataWorker?.cancel()
                self.tree = nil
                self.updateRows([])
                self.gitMetadata = .empty
                self.errorMessage = message
            }
        }

        let metadataBuilder = self.metadataBuilder
        let metadataWorker = Task.detached(priority: .utility) {
            await metadataBuilder(rootURL)
        }
        self.metadataWorker = metadataWorker
        metadataTask = Task { [weak self] in
            let metadata = await metadataWorker.value
            guard let self,
                  !Task.isCancelled,
                  generation == self.refreshGeneration else { return }
            if self.gitMetadata != metadata {
                self.gitMetadata = metadata
            }
        }
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
        url?.standardizedFileURL
    }

    private func rebuildRows() {
        let nextRows = PerformanceTrace.measure("FileTreeFlatten") {
            FileTreeBuilder.visibleRows(
                in: tree,
                collapsedDirectories: collapsedDirectories
            )
        }
        updateRows(nextRows)
    }

    private func updateRows(_ nextRows: [FileTreeRowModel]) {
        guard rows != nextRows else { return }
        rows = nextRows
        PerformanceTrace.fileTreePublished(rowCount: nextRows.count)
    }
}
