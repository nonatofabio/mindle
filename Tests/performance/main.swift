import AppKit
import Darwin
import Foundation
import SwiftUI

private struct BenchmarkResult {
    let name: String
    let unit: String
    let before: [Double]
    let after: [Double]
}

private final class RealizationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct CountingRow: View {
    let row: FileTreeRowModel
    let counter: RealizationCounter

    var body: some View {
        let _ = counter.increment()
        Text(row.name)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }
}

private struct BenchmarkRowList: View {
    let rows: [FileTreeRowModel]
    let lazy: Bool
    let counter: RealizationCounter

    @ViewBuilder
    var body: some View {
        ScrollView {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rowContent
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    rowContent
                }
            }
        }
        .frame(width: 320, height: 600)
    }

    private var rowContent: some View {
        ForEach(rows) { row in
            CountingRow(row: row, counter: counter)
        }
    }
}

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: file-browser-benchmark FIXTURE [RUNS] [GIT_FILES]\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let runs = Int(CommandLine.arguments.dropFirst(2).first ?? "5") ?? 5
let gitFileLimit = Int(CommandLine.arguments.dropFirst(3).first ?? "5") ?? 5

let warmTree = try FileTreeBuilder.build(at: root)
let warmRows = FileTreeBuilder.visibleRows(in: warmTree, collapsedDirectories: [])
_ = legacyBuildTree(at: root)
fputs("Benchmarking batched Git warm-up…\n", stderr)
_ = await GitMetadataCollector.collect(for: root)

fputs("Benchmarking tree scans…\n", stderr)
var legacyTreeTimes: [Double] = []
var dispatchTimes: [Double] = []
var workerTimes: [Double] = []
for _ in 0..<runs {
    let legacyStart = ContinuousClock.now
    _ = legacyBuildTree(at: root)
    legacyTreeTimes.append(legacyStart.duration(to: .now).benchmarkMilliseconds)

    let browser = await MainActor.run {
        FileBrowserState(metadataBuilder: { _ in .empty })
    }
    let workerStart = ContinuousClock.now
    let dispatch = await MainActor.run {
        let dispatchStart = ContinuousClock.now
        browser.setRoot(root)
        return dispatchStart.duration(to: .now).benchmarkMilliseconds
    }
    dispatchTimes.append(dispatch)
    await waitUntilLoaded(browser)
    workerTimes.append(workerStart.duration(to: .now).benchmarkMilliseconds)
}

var eagerRenderTimes: [Double] = []
var lazyRenderTimes: [Double] = []
var eagerRealizations: [Double] = []
var lazyRealizations: [Double] = []
fputs("Benchmarking eager and lazy row realization…\n", stderr)
for _ in 0..<runs {
    let eager = render(rows: warmRows, lazy: false)
    eagerRenderTimes.append(eager.milliseconds)
    eagerRealizations.append(Double(eager.realizedRows))

    let lazy = render(rows: warmRows, lazy: true)
    lazyRenderTimes.append(lazy.milliseconds)
    lazyRealizations.append(Double(lazy.realizedRows))
}

let benchmarkFiles = Array(
    warmRows.lazy
        .filter { $0.kind == .file }
        .prefix(gitFileLimit)
        .map(\.url)
)
var perFileGitTimes: [Double] = []
var batchedGitTimes: [Double] = []
fputs("Benchmarking per-file and batched Git metadata…\n", stderr)
for run in 0..<runs {
    fputs("  Git run \(run + 1)/\(runs): per-file baseline\n", stderr)
    let legacyGitStart = ContinuousClock.now
    legacyCollectGitMetadata(root: root, files: benchmarkFiles)
    perFileGitTimes.append(legacyGitStart.duration(to: .now).benchmarkMilliseconds)
    fputs("  Git run \(run + 1)/\(runs): batched collector\n", stderr)
    let start = ContinuousClock.now
    _ = await GitMetadataCollector.collect(for: root)
    batchedGitTimes.append(start.duration(to: .now).benchmarkMilliseconds)
}

private let results = [
    BenchmarkResult(
        name: "Main-thread refresh work",
        unit: "ms",
        before: legacyTreeTimes,
        after: dispatchTimes
    ),
    BenchmarkResult(
        name: "Tree scan to published rows",
        unit: "ms",
        before: legacyTreeTimes,
        after: workerTimes
    ),
    BenchmarkResult(
        name: "Initial 320×600 row render",
        unit: "ms",
        before: eagerRenderTimes,
        after: lazyRenderTimes
    ),
    BenchmarkResult(
        name: "Initially realized row bodies",
        unit: "rows",
        before: eagerRealizations,
        after: lazyRealizations
    ),
    BenchmarkResult(
        name: "Git changes + last-edited",
        unit: "ms",
        before: perFileGitTimes,
        after: batchedGitTimes
    )
]

print("Environment: \(ProcessInfo.processInfo.operatingSystemVersionString), \(machineDescription())")
print("Fixture: \(root.path)")
print("Visible rows: \(warmRows.count); Git files: \(benchmarkFiles.count); runs: \(runs)")
print("| Metric | Before median | After median | Before runs | After runs |")
print("|---|---:|---:|---|---|")
for result in results {
    print(
        "| \(result.name) | \(format(median(result.before))) \(result.unit)"
            + " | \(format(median(result.after))) \(result.unit)"
            + " | \(formatRuns(result.before)) | \(formatRuns(result.after)) |"
    )
}
print("Git process count per run: before \(benchmarkFiles.count * 2), after 3")

private func legacyBuildTree(at directory: URL) -> FileNode {
    let fileManager = FileManager.default
    let entries = (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []

    var children: [FileNode] = []
    for entry in entries {
        let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory {
            let nested = legacyBuildTree(at: entry)
            if !(nested.children ?? []).isEmpty {
                children.append(nested)
            }
        } else if FileTreeBuilder.isBrowsableFile(entry) {
            children.append(FileNode(
                url: entry.standardizedFileURL,
                name: entry.lastPathComponent,
                isDirectory: false,
                children: nil
            ))
        }
    }

    children.sort { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    return FileNode(
        url: directory.standardizedFileURL,
        name: directory.lastPathComponent,
        isDirectory: true,
        children: children
    )
}

private func legacyCollectGitMetadata(root: URL, files: [URL]) {
    for file in files {
        let relativePath = String(file.path.dropFirst(root.path.count + 1))
        runGit(["-C", root.path, "diff", "--numstat", "HEAD", "--", relativePath])
        runGit(["-C", root.path, "log", "-1", "--format=%ct", "--", relativePath])
    }
}

private func runGit(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C"
    ]) { _, new in new }
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return
    }
}

@MainActor
private func render(
    rows: [FileTreeRowModel],
    lazy: Bool
) -> (milliseconds: Double, realizedRows: Int) {
    let counter = RealizationCounter()
    let start = ContinuousClock.now
    let hostingView = NSHostingView(
        rootView: BenchmarkRowList(rows: rows, lazy: lazy, counter: counter)
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    return (start.duration(to: .now).benchmarkMilliseconds, counter.value())
}

@MainActor
private func waitUntilLoaded(_ browser: FileBrowserState) async {
    while browser.isLoading {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private extension Duration {
    var benchmarkMilliseconds: Double {
        Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let midpoint = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[midpoint - 1] + sorted[midpoint]) / 2
    }
    return sorted[midpoint]
}

private func format(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func formatRuns(_ values: [Double]) -> String {
    values.map(format).joined(separator: ", ")
}

private func machineDescription() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
    return String(cString: bytes)
}
